#!/usr/bin/env bash
# Ubuntu VM (QEMU, KVM if available, otherwise TCG) -> sshx -> link in docker logs
#
# Sleep/restart survival: while the VM runs, a live snapshot (RAM + disk state) is saved
# into /state every SNAPSHOT_INTERVAL_MIN minutes. If the container is stopped (e.g. the
# host "sleeps" it) and started again with the SAME /state volume, the VM is restored
# from that snapshot instead of being rebuilt, and the same sshx link is reused.
set -Eeuo pipefail

VM_DIR="${VM_DIR:-/state/ubuntu-vm}"
MEMORY_MIB="${MEMORY_MIB:-512}"               # guest RAM in MiB (container needs ~2x this)
DISK_SIZE="${DISK_SIZE:-20G}"
GUEST_SWAP_MB="${GUEST_SWAP_MB:-1024}"        # swap file INSIDE the guest (disk, not RAM)
TCG_TB_SIZE_MB="${TCG_TB_SIZE_MB:-64}"        # TCG code cache in host RAM (QEMU default is 1 GiB)
BOOT_TIMEOUT_MIN="${BOOT_TIMEOUT_MIN:-90}"    # TCG is slow, so be generous
GUEST_UNIT_TIMEOUT_SEC="${GUEST_UNIT_TIMEOUT_SEC:-900}"  # systemd device/start timeouts in guest (default 90s is too short under TCG)
DIRECT_KERNEL="${DIRECT_KERNEL:-1}"           # 1 = boot kernel/initrd directly (needed to pass boot options)
GUEST_APPARMOR="${GUEST_APPARMOR:-0}"         # 0 = boot guest with apparmor=0 (much faster under TCG)
SHOW_BOOT_LOG="${SHOW_BOOT_LOG:-1}"           # 1 = stream VM console to docker logs
RESUME="${RESUME:-1}"                         # 1 = restore the VM from the last snapshot if one exists
SNAPSHOT_INTERVAL_MIN="${SNAPSHOT_INTERVAL_MIN:-10}"     # 0 = never snapshot (no resume possible)
SNAPSHOT_FIRST_DELAY_SEC="${SNAPSHOT_FIRST_DELAY_SEC:-120}"  # first snapshot this long after the sshx link appears
SNAPSHOT_TIMEOUT_SEC="${SNAPSHOT_TIMEOUT_SEC:-600}"      # give up on one periodic snapshot after this long
SNAPSHOT_STOP_TIMEOUT_SEC="${SNAPSHOT_STOP_TIMEOUT_SEC:-20}"  # best-effort snapshot on docker stop (0 = skip)
RESUME_TIMEOUT_SEC="${RESUME_TIMEOUT_SEC:-180}"          # max wait for a restored VM to start running
IMAGE_BASE_URL="${IMAGE_BASE_URL:-https://cloud-images.ubuntu.com/noble/current}"
IMAGE_NAME="noble-server-cloudimg-amd64"
IMAGE_URL="${IMAGE_URL:-$IMAGE_BASE_URL/$IMAGE_NAME.img}"
KERNEL_URL="${KERNEL_URL:-$IMAGE_BASE_URL/unpacked/$IMAGE_NAME-vmlinuz-generic}"
INITRD_URL="${INITRD_URL:-$IMAGE_BASE_URL/unpacked/$IMAGE_NAME-initrd-generic}"

BASE_IMAGE="$VM_DIR/base.img"
KERNEL="$VM_DIR/vmlinuz"
INITRD="$VM_DIR/initrd"
DISK_IMAGE="$VM_DIR/disk.qcow2"
SEED_IMAGE="$VM_DIR/seed.iso"
SERIAL_LOG="$VM_DIR/serial.log"
SSHX_URL_FILE="$VM_DIR/sshx-url"
SNAP_FILE="$VM_DIR/snapshot-tag"
MON_SOCK="$VM_DIR/monitor.sock"
WEB_PID=""
WEB_PORT="${PORT:-8080}"

log() { printf '[qemu.sh] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

# ---- input validation --------------------------------------------------------
for v in GUEST_SWAP_MB SNAPSHOT_INTERVAL_MIN SNAPSHOT_STOP_TIMEOUT_SEC; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v must be a non-negative integer"
done
for v in MEMORY_MIB TCG_TB_SIZE_MB BOOT_TIMEOUT_MIN GUEST_UNIT_TIMEOUT_SEC \
         SNAPSHOT_FIRST_DELAY_SEC SNAPSHOT_TIMEOUT_SEC RESUME_TIMEOUT_SEC; do
  [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || die "$v must be a positive integer"
done
for v in DIRECT_KERNEL GUEST_APPARMOR SHOW_BOOT_LOG RESUME; do
  [[ "${!v}" == 0 || "${!v}" == 1 ]] || die "$v must be 0 or 1"
done

# CPUs: default = what the container may actually use (cgroup cpu.max), max 2.
# More vCPUs than real cores only makes TCG slower.
detect_cpus() {
  local n q p
  n=$(nproc 2>/dev/null || echo 1)
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    read -r q p < /sys/fs/cgroup/cpu.max || true
    if [[ "$q" =~ ^[0-9]+$ && "$p" =~ ^[1-9][0-9]*$ ]]; then
      q=$(( (q + p - 1) / p )); (( q < n )) && n=$q
    fi
  fi
  (( n < 1 )) && n=1; (( n > 2 )) && n=2
  echo "$n"
}
CPUS="${CPUS:-$(detect_cpus)}"
[[ "$CPUS" =~ ^[1-9][0-9]*$ ]] || die "CPUS must be a positive integer"
(( CPUS <= 2 )) || die "CPUS must be between 1 and 2"

for bin in wget sha256sum qemu-img cloud-localds qemu-system-x86_64 python3 pkill; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool not found: $bin"
done

mkdir -p "$VM_DIR"
[[ -w "$VM_DIR" ]] || die "VM_DIR is not writable: $VM_DIR"
[[ "$WEB_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( WEB_PORT <= 65535 )) || die "PORT must be an integer from 1 to 65535"

# >>> snapshot helpers (talk to the QEMU monitor socket) >>>
# mon TIMEOUT_SEC "hmp command" -> prints the command output; non-zero on failure/timeout
mon() {
  python3 - "$MON_SOCK" "$1" "$2" <<'PY'
import re, socket, sys, time
path, timeout, cmd = sys.argv[1], float(sys.argv[2]), sys.argv[3]
deadline = time.time() + timeout
ansi = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(1.0)
try:
    s.connect(path)
except OSError as e:
    sys.stderr.write("monitor connect failed: %s\n" % e)
    sys.exit(2)

def read_prompt():
    buf = b""
    while time.time() < deadline:
        try:
            d = s.recv(65536)
        except socket.timeout:
            continue
        except OSError:
            return None
        if not d:
            return None
        buf += d
        clean = ansi.sub(b"", buf)
        if clean.rstrip().endswith(b"(qemu)"):
            return clean.decode("utf-8", "replace")
    return None

if read_prompt() is None:
    sys.exit(3)
s.sendall(cmd.encode() + b"\n")
out = read_prompt()
if out is None:
    sys.exit(3)
sys.stdout.write(out.replace("\r", ""))
PY
}

# snapshot_tags -> one snapshot tag per line (disk must not be in use, or be read-only safe)
snapshot_tags() {
  qemu-img snapshot -l "$DISK_IMAGE" 2>/dev/null | awk 'NR>2 {print $2}' || true
}

# prune_snapshots KEEP_TAG -> delete every internal snapshot except KEEP_TAG (may be empty)
# Only call while QEMU is NOT running.
prune_snapshots() {
  local keep=${1:-} t
  while read -r t; do
    if [[ -n "$t" && "$t" != "$keep" ]]; then
      qemu-img snapshot -d "$t" "$DISK_IMAGE" >/dev/null 2>&1 || true
    fi
  done < <(snapshot_tags)
}

# take_snapshot TIMEOUT_SEC [keep]  (second arg "keep" = do not delete the previous snapshot)
take_snapshot() {
  local timeout=$1 mode=${2:-} tag old="" out
  tag="s$(date +%s)"
  [[ -s "$SNAP_FILE" ]] && old=$(head -n1 "$SNAP_FILE")
  out=$(mon "$timeout" "savevm $tag") || { log "snapshot: monitor error or timeout"; return 1; }
  if grep -qi 'error' <<<"$out"; then log "snapshot failed: $out"; return 1; fi
  out=$(mon 30 "info snapshots") || { log "snapshot: could not verify"; return 1; }
  grep -qw -- "$tag" <<<"$out" || { log "snapshot $tag missing after savevm"; return 1; }
  printf '%s\n' "$tag" > "$SNAP_FILE.part"
  mv -f "$SNAP_FILE.part" "$SNAP_FILE"
  if [[ "$mode" != keep && -n "$old" && "$old" != "$tag" ]]; then
    mon 120 "delvm $old" >/dev/null 2>&1 || true
  fi
  log "VM snapshot saved ($tag)"
}

# wait_resumed -> 0 once the restored VM reports "running", 1 if QEMU died or timed out
wait_resumed() {
  local start=$SECONDS out
  while (( SECONDS - start < RESUME_TIMEOUT_SEC )); do
    kill -0 "$QEMU_PID" 2>/dev/null || return 1
    if out=$(mon 10 "info status" 2>/dev/null) && grep -q 'running' <<<"$out"; then
      return 0
    fi
    sleep 2
  done
  return 1
}
# <<< snapshot helpers <<<

QEMU_PID=""; TAIL_PID=""; SNAP_PID=""; WATCH_PID=""; SNAP_READY=0

stop_bg() {
  local p
  for p in "$SNAP_PID" "$WATCH_PID"; do
    if [[ -n "$p" ]]; then
      pkill -P "$p" 2>/dev/null || true
      kill "$p" 2>/dev/null || true
    fi
  done
  SNAP_PID=""; WATCH_PID=""
}

cleanup() {
  stop_bg
  [[ -n "$WEB_PID" ]] && kill "$WEB_PID" 2>/dev/null || true
  [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null || true
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    if (( SNAP_READY == 1 && SNAPSHOT_INTERVAL_MIN > 0 && SNAPSHOT_STOP_TIMEOUT_SEC > 0 )); then
      log "Saving a final VM snapshot (max ${SNAPSHOT_STOP_TIMEOUT_SEC}s)..."
      take_snapshot "$SNAPSHOT_STOP_TIMEOUT_SEC" keep || log "final snapshot skipped"
    fi
    log "Stopping VM..."
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  rm -f "$MON_SOCK" 2>/dev/null || true
  rm -f "${LOCK_DIR:-}/pid" 2>/dev/null || true
  rmdir "${LOCK_DIR:-}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Keep the old sshx link only if there is a snapshot that can bring that session back.
if [[ "$RESUME" != 1 || ! -s "$SNAP_FILE" ]]; then
  rm -f "$SSHX_URL_FILE" "$SSHX_URL_FILE.part"
fi
python3 /usr/local/bin/sshx-redirect.py --host 0.0.0.0 --port "$WEB_PORT" --url-file "$SSHX_URL_FILE" &
WEB_PID=$!
sleep 0.1
kill -0 "$WEB_PID" 2>/dev/null || die "HTTP redirect server failed to start on port $WEB_PORT"
log "HTTP redirect server listening on 0.0.0.0:$WEB_PORT"

LOCK_DIR="$VM_DIR/.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # A lock left by a killed container is stale. In a fresh container this script is often
  # PID 1 again, so a lock holding our own PID is stale too.
  if [[ -r "$LOCK_DIR/pid" ]] && read -r LOCK_PID < "$LOCK_DIR/pid" &&
     [[ "$LOCK_PID" =~ ^[1-9][0-9]*$ ]] &&
     { [[ "$LOCK_PID" == "$$" ]] || ! kill -0 "$LOCK_PID" 2>/dev/null; }; then
    log "Removing stale lock from PID $LOCK_PID"
    rm -rf -- "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || die "another VM is already using $VM_DIR"
  else
    die "another VM is already using $VM_DIR"
  fi
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"

if [[ -r /sys/fs/cgroup/memory.max ]]; then
  MEMORY_LIMIT=$(cat /sys/fs/cgroup/memory.max)
  MIN_LIMIT=$(( MEMORY_MIB * 2 * 1024 * 1024 ))
  log "Container memory limit: $MEMORY_LIMIT (needs ~$((MEMORY_MIB * 2))MiB+ for ${MEMORY_MIB}M guest + QEMU)"
  if [[ "$MEMORY_LIMIT" =~ ^[0-9]+$ ]] && (( MEMORY_LIMIT < MIN_LIMIT )); then
    die "container memory limit is below $((MEMORY_MIB * 2))MiB; lower MEMORY_MIB or raise the limit"
  fi
fi

# ---- downloads ---------------------------------------------------------------
# Only fetch publisher-controlled HTTPS URLs. Downloads are atomic and verified.
require_https_url() {
  [[ "$1" == https://* ]] || die "URL must use HTTPS: $1"
}
# fetch URL DEST: download atomically, verify against SHA256SUMS of its directory
fetch() {
  require_https_url "$1"
  local url=$1 dest=$2 name sums
  name=${url##*/}
  log "Downloading $name..."
  rm -f "$dest.part"
  wget -q --show-progress --progress=dot:giga --tries=3 --timeout=30 -O "$dest.part" "$url" || { rm -f "$dest.part"; return 1; }
  sums=$(wget -qO- --tries=3 --timeout=30 "${url%/*}/SHA256SUMS" 2>/dev/null | awk -v n="$name" '{gsub(/^\*/, "", $NF); if ($NF == n) {print $1; exit}}' || true)
  [[ "$sums" =~ ^[0-9a-fA-F]{64}$ ]] || { rm -f "$dest.part"; log "no valid SHA256 entry for $name"; return 1; }
  if [[ -n "$sums" ]]; then
    if [[ "$(sha256sum "$dest.part" | awk '{print $1}')" != "$sums" ]]; then
      rm -f "$dest.part"; log "checksum mismatch for $name"; return 1
    fi
    log "$name checksum OK"
  else
    log "WARNING: no checksum available for $name, skipping verification"
  fi
  mv "$dest.part" "$dest"
}

if [[ "$DIRECT_KERNEL" == 1 && -s "$BASE_IMAGE" && ! ( -s "$KERNEL" && -s "$INITRD" ) ]]; then
  # kernel/initrd must come from the same build as base.img -> refresh all three
  log "Kernel/initrd missing for existing image -> re-downloading matching set"
  rm -f "$BASE_IMAGE" "$DISK_IMAGE"
fi
if [[ ! -s "$BASE_IMAGE" ]]; then
  fetch "$IMAGE_URL" "$BASE_IMAGE" || die "image download failed"
  rm -f "$DISK_IMAGE" "$KERNEL" "$INITRD"     # new backing file -> new overlay
fi
if [[ "$DIRECT_KERNEL" == 1 && ! ( -s "$KERNEL" && -s "$INITRD" ) ]]; then
  if ! { fetch "$KERNEL_URL" "$KERNEL" && fetch "$INITRD_URL" "$INITRD"; }; then
    die "kernel/initrd download failed; refusing to boot an unverified build"
  fi
fi
if [[ ! -f "$DISK_IMAGE" ]]; then
  log "Creating VM disk ($DISK_SIZE)..."
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK_IMAGE" "$DISK_SIZE"
fi

# ---- cloud-init (tuned for small guests) -------------------------------------
# - no packages/package_update: apt update -> appstreamcli/apt-check -> OOM.
#   curl already ships in the Ubuntu server cloud image.
# - bootcmd (every boot, before anything heavy): swap file, mask heavy services,
#   persist longer systemd timeouts + nofail for /boot,/boot/efi (GRUB-boot path).
# - timefix.service: after a snapshot resume the guest clock is stale; re-syncing it
#   keeps TLS (and therefore the sshx reconnect) working.
# Only used on a cold boot; a resumed VM keeps the seed it was started with.
write_seed() {
cat > "$VM_DIR/user-data" <<CLOUD
#cloud-config
hostname: ubuntu-sshx
preserve_hostname: false
package_update: false
package_upgrade: false
package_reboot_if_required: false
growpart:
  mode: auto
resize_rootfs: true
cloud_init_modules:
  - bootcmd
  - growpart
  - resizefs
cloud_config_modules:
  - write-files
  - runcmd
cloud_final_modules:
  - scripts-user
package_upgrade: false
package_reboot_if_required: false
bootcmd:
  - [sh, -c, 'command -v growpart >/dev/null 2>&1 && growpart /dev/vda 1 >/dev/null 2>&1 || true; command -v resize2fs >/dev/null 2>&1 && resize2fs /dev/vda1 >/dev/null 2>&1 || true; S=${GUEST_SWAP_MB}; if [ "\$S" -gt 0 ] && ! swapon --show=NAME --noheadings | grep -q /swapfile; then [ -f /swapfile ] || { fallocate -l \${S}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=\$S; chmod 600 /swapfile; mkswap /swapfile; }; swapon /swapfile; fi; sysctl -w vm.swappiness=60 >/dev/null; true']
  - [sh, -c, 'for u in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service motd-news.timer motd-news.service man-db.timer fwupd-refresh.timer packagekit.service ModemManager.service udisks2.service multipathd.service multipathd.socket fwupd.service; do systemctl --no-block stop "\$u" 2>/dev/null; systemctl mask "\$u" 2>/dev/null; done; true']
  - [sh, -c, 'rm -f /etc/apt/apt.conf.d/50appstream /etc/apt/apt.conf.d/99update-notifier; chmod -x /etc/update-motd.d/50-motd-news /etc/update-motd.d/90-updates-available /etc/update-motd.d/91-release-upgrade 2>/dev/null; true']
  - [sh, -c, 'mkdir -p /etc/systemd/system.conf.d; printf "[Manager]\nDefaultTimeoutStartSec=${GUEST_UNIT_TIMEOUT_SEC}s\nDefaultDeviceTimeoutSec=${GUEST_UNIT_TIMEOUT_SEC}s\n" > /etc/systemd/system.conf.d/90-slow-tcg.conf; sed -i -E "/LABEL=(BOOT|UEFI)[[:space:]]/{/nofail/!s/^([^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)([^[:space:]]+)/\1\2,nofail,x-systemd.device-timeout=${GUEST_UNIT_TIMEOUT_SEC}s/}" /etc/fstab; true']
write_files:
  - path: /usr/local/bin/run-sshx.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      export HOME=/root SHELL=/bin/bash TERM=xterm-256color
      export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      until command -v sshx >/dev/null 2>&1; do
        echo "SSHX-INFO: installing sshx..." > /dev/ttyS0
        tmp=\$(mktemp) || { sleep 5; continue; }
        if command -v curl >/dev/null 2>&1; then
          curl --fail --show-error --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --output "\$tmp" https://sshx.io/get
        else
          wget --https-only --tries=3 --timeout=15 -O "\$tmp" https://sshx.io/get
        fi
        rc=\$?
        if [ "\$rc" -eq 0 ] && [ -s "\$tmp" ]; then
          sh "\$tmp" > /dev/ttyS0 2>&1 || true
        fi
        rm -f "\$tmp"
        command -v sshx >/dev/null 2>&1 || sleep 5
      done
      echo "SSHX-INFO: starting sshx" > /dev/ttyS0
      sshx 2>&1 | sed -u 's/^/SSHX-OUT: /' > /dev/ttyS0
  - path: /etc/systemd/system/sshx.service
    content: |
      [Unit]
      Description=sshx terminal sharing
      Wants=network-online.target
      After=network-online.target
      [Service]
      ExecStart=/usr/local/bin/run-sshx.sh
      Restart=always
      RestartSec=5
      OOMScoreAdjust=-500
      [Install]
      WantedBy=multi-user.target
  - path: /etc/systemd/system/timefix.service
    content: |
      [Unit]
      Description=Re-sync guest clock (needed after a VM snapshot resume)
      [Service]
      ExecStart=/bin/sh -c 'while sleep 120; do systemctl restart systemd-timesyncd; done'
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --no-block, --now, sshx.service]
  - [systemctl, enable, --no-block, --now, timefix.service]
CLOUD
# new instance-id every cold start => cloud-init always re-applies the config
printf 'instance-id: sshx-%s-%s\nlocal-hostname: ubuntu-sshx\n' "$(date +%s)" "$$" > "$VM_DIR/meta-data"
cloud-localds "$SEED_IMAGE" "$VM_DIR/user-data" "$VM_DIR/meta-data"
}

# ---- accelerator -------------------------------------------------------------
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  log "KVM detected -> hardware acceleration"
  ACCEL=(-accel kvm -cpu host)
else
  log "KVM not available -> TCG software emulation (slow, can take 10-40 min)"
  ACCEL=(-accel "tcg,thread=multi,tb-size=${TCG_TB_SIZE_MB}" -cpu max)
fi

# ---- boot options (direct kernel boot only) ----------------------------------
BOOT=()
if [[ "$DIRECT_KERNEL" == 1 ]]; then
  T=$GUEST_UNIT_TIMEOUT_SEC
  CMDLINE="root=LABEL=cloudimg-rootfs ro console=ttyS0,115200n8 ds=nocloud"
  CMDLINE+=" systemd.default_device_timeout_sec=$T systemd.default_timeout_start_sec=$T"
  for u in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service \
           unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer \
           motd-news.timer man-db.timer fwupd-refresh.timer ModemManager.service \
           multipathd.service multipathd.socket udisks2.service packagekit.service; do
    CMDLINE+=" systemd.mask=$u"
  done
  [[ "$GUEST_APPARMOR" == 0 ]] && CMDLINE+=" apparmor=0"
  BOOT=(-kernel "$KERNEL" -initrd "$INITRD" -append "$CMDLINE")
  log "Direct kernel boot: $CMDLINE"
else
  log "Disk (GRUB) boot: guest timeouts apply from the 2nd boot on"
fi

# launch_qemu [SNAPSHOT_TAG]  -> starts QEMU in the background and sets QEMU_PID.
# The machine definition must stay identical between runs, otherwise a snapshot cannot be loaded.
launch_qemu() {
  local extra=()
  [[ -n "${1:-}" ]] && extra=(-loadvm "$1")
  rm -f "$MON_SOCK"
  qemu-system-x86_64 "${ACCEL[@]}" \
    -machine q35 -m "${MEMORY_MIB}M" -smp "$CPUS" \
    "${BOOT[@]}" "${extra[@]}" \
    -drive "file=$DISK_IMAGE,if=virtio,format=qcow2,cache=unsafe,aio=threads" \
    -drive "file=$SEED_IMAGE,if=virtio,format=raw,readonly=on" \
    -nic user,model=virtio-net-pci \
    -device virtio-rng-pci \
    -vga none -display none -no-reboot \
    -monitor "unix:$MON_SOCK,server,nowait" \
    -chardev "file,id=ser0,path=$SERIAL_LOG,append=on" -serial chardev:ser0 &
  QEMU_PID=$!
}

# ---- resume or cold boot -----------------------------------------------------
RESUME_TAG=""; RESUMED=0
if [[ "$RESUME" == 1 && -s "$SNAP_FILE" && -s "$SSHX_URL_FILE" && -s "$DISK_IMAGE" && -s "$SEED_IMAGE" ]]; then
  cand=$(head -n1 "$SNAP_FILE")
  snaps=$(snapshot_tags)
  if [[ -n "$cand" ]] && grep -qxF -- "$cand" <<<"$snaps"; then RESUME_TAG=$cand; fi
fi

if [[ -n "$RESUME_TAG" ]]; then
  log "Found VM snapshot $RESUME_TAG -> resuming the previous VM (same sshx session)..."
  prune_snapshots "$RESUME_TAG"
  launch_qemu "$RESUME_TAG"
  if wait_resumed; then
    RESUMED=1
    log "VM resumed from snapshot"
  else
    log "WARNING: resume failed -> falling back to a cold boot (disk data is kept)"
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
  fi
fi

if (( RESUMED == 0 )); then
  prune_snapshots ""
  rm -f "$SNAP_FILE" "$SNAP_FILE.part" "$SSHX_URL_FILE" "$SSHX_URL_FILE.part"
  write_seed
  : > "$SERIAL_LOG"
  log "Booting Ubuntu (guest RAM=${MEMORY_MIB}M, guest swap=${GUEST_SWAP_MB}M, CPUs=$CPUS)..."
  launch_qemu ""
fi

if [[ "$SHOW_BOOT_LOG" == "1" ]]; then
  if (( RESUMED == 1 )); then TAIL_FROM="-n 0"; else TAIL_FROM="-n +1"; fi
  # shellcheck disable=SC2086
  tail $TAIL_FROM -F "$SERIAL_LOG" 2>/dev/null \
    | sed -u -r 's/\x1B\[[0-9;?]*[A-Za-z]//g; s/\r//g; s/^/[vm] /' &
  TAIL_PID=$!
fi

# latest sshx link printed on the guest console
latest_url() {
  tail -c 2000000 "$SERIAL_LOG" 2>/dev/null | sed -r 's/\x1B\[[0-9;?]*[A-Za-z]//g' \
    | grep -a 'SSHX-OUT' \
    | grep -aoE 'https://sshx\.io/s/[A-Za-z0-9_-]+#[A-Za-z0-9_-]+' | tail -n 1 || true
}
publish_url() {
  printf '%s\n' "$1" > "$SSHX_URL_FILE.part"
  mv -f "$SSHX_URL_FILE.part" "$SSHX_URL_FILE"
}

# ---- wait for the sshx link --------------------------------------------------
URL=""
if (( RESUMED == 1 )); then
  URL=$(head -n1 "$SSHX_URL_FILE")
  log "Reusing the previous sshx link; the guest's sshx client will reconnect by itself."
fi
START=$(date +%s); LAST=0; OOM_WARNED=0
while [[ -z "$URL" ]]; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    RC=0; wait "$QEMU_PID" 2>/dev/null || RC=$?
    QEMU_PID=""
    log "QEMU exited unexpectedly (exit code $RC). Last console lines:"
    tail -n 50 "$SERIAL_LOG" || true
    exit 1
  fi
  URL=$(latest_url)
  if [[ -n "$URL" ]]; then
    publish_url "$URL"
  fi
  if (( OOM_WARNED == 0 )) && grep -aq 'Out of memory: Killed process' "$SERIAL_LOG" 2>/dev/null; then
    log "WARNING: guest OOM killer fired (see [vm] lines)"; OOM_WARNED=1
  fi
  ELAPSED=$(( ($(date +%s) - START) / 60 ))
  if (( ELAPSED >= BOOT_TIMEOUT_MIN )); then
    log "No sshx link after ${BOOT_TIMEOUT_MIN} min. Last console lines:"
    tail -n 50 "$SERIAL_LOG" || true
    exit 1
  fi
  if (( ELAPSED > LAST )); then LAST=$ELAPSED; log "still booting... ${ELAPSED} min"; fi
  [[ -z "$URL" ]] && sleep 5
done

[[ -n "$TAIL_PID" ]] && { kill "$TAIL_PID" 2>/dev/null || true; TAIL_PID=""; }
printf '\n==================== SSHX LINK ====================\n'
printf '%s\n' "$URL"
printf '===================================================\n\n'

# ---- background jobs: periodic snapshots + follow link changes ---------------
snapshot_loop() {
  sleep "$SNAPSHOT_FIRST_DELAY_SEC"
  while kill -0 "$QEMU_PID" 2>/dev/null; do
    take_snapshot "$SNAPSHOT_TIMEOUT_SEC" || log "WARNING: periodic snapshot failed"
    sleep $(( SNAPSHOT_INTERVAL_MIN * 60 ))
  done
}
url_watch() {
  local cur=$1 new
  while sleep 15; do
    new=$(latest_url)
    if [[ -n "$new" && "$new" != "$cur" ]]; then
      cur=$new
      publish_url "$new"
      log "sshx link changed: $new"
    fi
  done
}
SNAP_READY=1
if (( SNAPSHOT_INTERVAL_MIN > 0 )); then
  snapshot_loop &
  SNAP_PID=$!
  log "Snapshots enabled: first one in ${SNAPSHOT_FIRST_DELAY_SEC}s, then every ${SNAPSHOT_INTERVAL_MIN} min"
else
  log "Snapshots disabled (SNAPSHOT_INTERVAL_MIN=0): the VM cannot be resumed after a restart"
fi
url_watch "$URL" &
WATCH_PID=$!

log "VM is running. Stop with: docker stop -t 60 <container>"
RC=0; wait "$QEMU_PID" || RC=$?
QEMU_PID=""
stop_bg
log "QEMU exited (exit code $RC)"
exit "$RC"
