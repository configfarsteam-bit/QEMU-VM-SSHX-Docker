#!/usr/bin/env bash
# Ubuntu VM in QEMU, using KVM when available and TCG otherwise.
set -Eeuo pipefail

VM_DIR="${VM_DIR:-/state/ubuntu-vm}"
MEMORY_MIB="${MEMORY_MIB:-${MEMORY:-512}}"
DISK_SIZE="${DISK_SIZE:-20G}"
GUEST_SWAP_MB="${GUEST_SWAP_MB:-1024}"
TCG_TB_SIZE_MB="${TCG_TB_SIZE_MB:-128}"
BOOT_TIMEOUT_MIN="${BOOT_TIMEOUT_MIN:-30}"
GUEST_UNIT_TIMEOUT_SEC="${GUEST_UNIT_TIMEOUT_SEC:-180}"
DIRECT_KERNEL="${DIRECT_KERNEL:-1}"
GUEST_APPARMOR="${GUEST_APPARMOR:-1}"
SHOW_BOOT_LOG="${SHOW_BOOT_LOG:-1}"
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
SEED_STAMP="$VM_DIR/seed.sha256"

log() { printf '[qemu.sh] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ "$MEMORY_MIB" =~ ^[1-9][0-9]*$ ]] || die "MEMORY_MIB must be a positive integer"
(( MEMORY_MIB >= 384 )) || die "MEMORY_MIB must be at least 384 MiB"
for v in GUEST_SWAP_MB; do [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v must be a non-negative integer"; done
for v in TCG_TB_SIZE_MB BOOT_TIMEOUT_MIN GUEST_UNIT_TIMEOUT_SEC; do
  [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || die "$v must be a positive integer"
done
for v in DIRECT_KERNEL GUEST_APPARMOR SHOW_BOOT_LOG; do
  [[ "${!v}" == 0 || "${!v}" == 1 ]] || die "$v must be 0 or 1"
done

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

for bin in wget sha256sum qemu-img cloud-localds qemu-system-x86_64; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool not found: $bin"
done

mkdir -p "$VM_DIR"
[[ -w "$VM_DIR" ]] || die "VM_DIR is not writable: $VM_DIR"
LOCK_DIR="$VM_DIR/.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [[ -r "$LOCK_DIR/pid" ]] && read -r LOCK_PID < "$LOCK_DIR/pid" &&
     [[ "$LOCK_PID" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$LOCK_PID" 2>/dev/null; then
    log "Removing stale lock from PID $LOCK_PID"
    rm -rf -- "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || die "another VM is already using $VM_DIR"
  else
    die "another VM is already using $VM_DIR"
  fi
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"

QEMU_PID=""; TAIL_PID=""
cleanup() {
  [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null || true
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    log "Stopping VM..."
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  rm -f "${LOCK_DIR:-}/pid" 2>/dev/null || true
  rmdir "${LOCK_DIR:-}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [[ -r /sys/fs/cgroup/memory.max ]]; then
  MEMORY_LIMIT=$(cat /sys/fs/cgroup/memory.max)
  if [[ "$MEMORY_LIMIT" =~ ^[0-9]+$ ]]; then
    REQUIRED=$(( (MEMORY_MIB + 256) * 1024 * 1024 ))
    (( MEMORY_LIMIT >= REQUIRED )) || die "container memory limit is too low for ${MEMORY_MIB}MiB guest plus QEMU overhead"
    log "Container memory limit: $MEMORY_LIMIT bytes"
  fi
fi

require_https_url() { [[ "$1" == https://* ]] || die "URL must use HTTPS: $1"; }
fetch() {
  require_https_url "$1"
  local url=$1 dest=$2 name sums
  name=${url##*/}
  if [[ -s "$dest" ]]; then log "$name already cached"; return 0; fi
  log "Downloading $name..."
  rm -f "$dest.part"
  wget -q --show-progress --progress=dot:giga --tries=3 --timeout=30 -O "$dest.part" "$url" || { rm -f "$dest.part"; return 1; }
  sums=$(wget -qO- --tries=3 --timeout=30 "${url%/*}/SHA256SUMS" 2>/dev/null | awk -v n="$name" '{gsub(/^\*/, "", $NF); if ($NF == n) {print $1; exit}}' || true)
  [[ "$sums" =~ ^[0-9a-fA-F]{64}$ ]] || { rm -f "$dest.part"; log "no valid SHA256 entry for $name"; return 1; }
  [[ "$(sha256sum "$dest.part" | awk '{print $1}')" == "$sums" ]] || { rm -f "$dest.part"; log "checksum mismatch for $name"; return 1; }
  log "$name checksum OK"
  mv "$dest.part" "$dest"
}

if [[ "$DIRECT_KERNEL" == 1 && -s "$BASE_IMAGE" && ! ( -s "$KERNEL" && -s "$INITRD" ) ]]; then
  log "Kernel/initrd missing for existing image, refreshing matching set"
  rm -f "$BASE_IMAGE" "$DISK_IMAGE"
fi
if [[ ! -s "$BASE_IMAGE" ]]; then
  fetch "$IMAGE_URL" "$BASE_IMAGE" || die "image download failed"
  rm -f "$DISK_IMAGE" "$KERNEL" "$INITRD"
fi
if [[ "$DIRECT_KERNEL" == 1 && ! ( -s "$KERNEL" && -s "$INITRD" ) ]]; then
  fetch "$KERNEL_URL" "$KERNEL" || die "kernel download failed"
  fetch "$INITRD_URL" "$INITRD" || die "initrd download failed"
fi
if [[ ! -f "$DISK_IMAGE" ]]; then
  log "Creating VM overlay disk ($DISK_SIZE)..."
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK_IMAGE" "$DISK_SIZE"
fi

# Keep the same cloud-init instance across restarts. Recreating instance-id on every
# launch made cloud-init redo first-boot work, including the SSHX installation.
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
bootcmd:
  - [sh, -c, 'command -v growpart >/dev/null 2>&1 && growpart /dev/vda 1 >/dev/null 2>&1 || true; command -v resize2fs >/dev/null 2>&1 && resize2fs /dev/vda1 >/dev/null 2>&1 || true; S=${GUEST_SWAP_MB}; if [ "\$S" -gt 0 ] && ! swapon --show=NAME --noheadings | grep -q /swapfile; then [ -f /swapfile ] || { fallocate -l \${S}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=\$S; chmod 600 /swapfile; mkswap /swapfile; }; swapon /swapfile; fi; sysctl -w vm.swappiness=60 >/dev/null; true']
  - [sh, -c, 'for u in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service motd-news.timer motd-news.service man-db.timer fwupd-refresh.timer packagekit.service ModemManager.service udisks2.service multipathd.service multipathd.socket fwupd.service; do systemctl --no-block stop "\$u" 2>/dev/null; systemctl mask "\$u" 2>/dev/null; done; true']
  - [sh, -c, 'rm -f /etc/apt/apt.conf.d/50appstream /etc/apt/apt.conf.d/99update-notifier; chmod -x /etc/update-motd.d/50-motd-news /etc/update-motd.d/90-updates-available /etc/update-motd.d/91-release-upgrade 2>/dev/null; true']
  - [sh, -c, 'mkdir -p /etc/systemd/system.conf.d; printf "[Manager]\nDefaultTimeoutStartSec=${GUEST_UNIT_TIMEOUT_SEC}s\nDefaultDeviceTimeoutSec=${GUEST_UNIT_TIMEOUT_SEC}s\n" > /etc/systemd/system.conf.d/90-slow-tcg.conf; sed -i -E "/LABEL=(BOOT|UEFI)[[:space:]]/{/nofail/!s/^([^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+)([^[:space:]]+)/\1\2,nofail,x-systemd.device-timeout=${GUEST_UNIT_TIMEOUT_SEC}s/}" /etc/fstab; true']
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
        if [ "\$rc" -eq 0 ] && [ -s "\$tmp" ]; then sh "\$tmp" > /dev/ttyS0 2>&1 || true; fi
        rm -f "\$tmp"
        command -v sshx >/dev/null 2>&1 || sleep 5
      done
      echo "SSHX-INFO: starting sshx" > /dev/ttyS0
      exec sshx 2>&1 | sed -u 's/^/SSHX-OUT: /' > /dev/ttyS0
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
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, sshx.service]
CLOUD
printf 'instance-id: sshx-persistent\nlocal-hostname: ubuntu-sshx\n' > "$VM_DIR/meta-data"
SEED_HASH=$(sha256sum "$VM_DIR/user-data" "$VM_DIR/meta-data" | sha256sum | awk '{print $1}')
if [[ ! -s "$SEED_IMAGE" || ! -r "$SEED_STAMP" || "$(cat "$SEED_STAMP" 2>/dev/null || true)" != "$SEED_HASH" ]]; then
  log "Building cloud-init seed (only when configuration changes)"
  cloud-localds "$SEED_IMAGE.part" "$VM_DIR/user-data" "$VM_DIR/meta-data"
  mv "$SEED_IMAGE.part" "$SEED_IMAGE"
  printf '%s\n' "$SEED_HASH" > "$SEED_STAMP"
else
  log "Cloud-init seed already cached"
fi

if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  log "KVM detected -> hardware acceleration"
  ACCEL=(-accel kvm -cpu host)
else
  log "KVM not available -> TCG software emulation"
  TCG_CPU=qemu64
  qemu-system-x86_64 -cpu help 2>/dev/null | grep -qE '^\s+max\s' && TCG_CPU=max
  ACCEL=(-accel "tcg,thread=multi,tb-size=${TCG_TB_SIZE_MB}" -cpu "$TCG_CPU")
  log "TCG CPU model: $TCG_CPU"
fi

BOOT=()
if [[ "$DIRECT_KERNEL" == 1 ]]; then
  T=$GUEST_UNIT_TIMEOUT_SEC
  CMDLINE="root=LABEL=cloudimg-rootfs ro console=ttyS0,115200n8 ds=nocloud"
  CMDLINE+=" systemd.default_device_timeout_sec=$T systemd.default_timeout_start_sec=$T"
  for u in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer motd-news.timer man-db.timer fwupd-refresh.timer ModemManager.service multipathd.service multipathd.socket udisks2.service packagekit.service; do
    CMDLINE+=" systemd.mask=$u"
  done
  [[ "$GUEST_APPARMOR" == 0 ]] && CMDLINE+=" apparmor=0"
  BOOT=(-kernel "$KERNEL" -initrd "$INITRD" -append "$CMDLINE")
fi

: > "$SERIAL_LOG"
log "Booting Ubuntu (guest RAM=${MEMORY_MIB}M, guest swap=${GUEST_SWAP_MB}M, CPUs=$CPUS)..."
qemu-system-x86_64 "${ACCEL[@]}" \
  -machine q35 -m "${MEMORY_MIB}M" -smp "$CPUS" \
  "${BOOT[@]}" \
  -drive "file=$DISK_IMAGE,if=virtio,format=qcow2,cache=writeback,aio=threads" \
  -drive "file=$SEED_IMAGE,if=virtio,format=raw,readonly=on,cache=unsafe" \
  -nic user,model=virtio-net-pci \
  -device virtio-rng-pci -vga none -display none -monitor none -no-reboot \
  -serial "file:$SERIAL_LOG" &
QEMU_PID=$!

if [[ "$SHOW_BOOT_LOG" == "1" ]]; then
  tail -n +1 -F "$SERIAL_LOG" 2>/dev/null | sed -u -r 's/\x1B\[[0-9;?]*[A-Za-z]//g; s/\r//g; s/^/[vm] /' &
  TAIL_PID=$!
fi

URL=""; START=$(date +%s); LAST_REPORT=-1; OOM_WARNED=0; TIMEOUT_SEC=$((BOOT_TIMEOUT_MIN * 60))
while [[ -z "$URL" ]]; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    RC=0; wait "$QEMU_PID" 2>/dev/null || RC=$?; QEMU_PID=""
    log "QEMU exited unexpectedly (exit code $RC). Last console lines:"
    tail -n 50 "$SERIAL_LOG" || true
    exit 1
  fi
  URL=$(tail -c 131072 "$SERIAL_LOG" | sed -r 's/\x1B\[[0-9;?]*[A-Za-z]//g' | grep -aoE 'https://sshx\.io/s/[A-Za-z0-9_-]+#[A-Za-z0-9_-]+' | tail -n 1 || true)
  if (( OOM_WARNED == 0 )) && grep -aq 'Out of memory: Killed process' "$SERIAL_LOG" 2>/dev/null; then
    log "WARNING: guest OOM killer fired"; OOM_WARNED=1
  fi
  NOW=$(date +%s); ELAPSED=$((NOW - START))
  (( ELAPSED >= TIMEOUT_SEC )) && { log "No sshx link after ${BOOT_TIMEOUT_MIN} min"; tail -n 50 "$SERIAL_LOG" || true; exit 1; }
  REPORT=$((ELAPSED / 60))
  if (( REPORT > LAST_REPORT )); then LAST_REPORT=$REPORT; log "still booting... ${REPORT} min"; fi
  [[ -z "$URL" ]] && sleep 2
done

[[ -n "$TAIL_PID" ]] && { kill "$TAIL_PID" 2>/dev/null || true; TAIL_PID=""; }
printf '\n==================== SSHX LINK ====================\n%s\n===================================================\n\n' "$URL"
log "VM is running. Stop with: docker stop <container>"
RC=0; wait "$QEMU_PID" || RC=$?; QEMU_PID=""
log "QEMU exited (exit code $RC)"
exit "$RC"
