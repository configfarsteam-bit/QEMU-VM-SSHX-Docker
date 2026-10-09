#!/usr/bin/env bash
# Ubuntu VM (QEMU, KVM if available, otherwise TCG) -> sshx -> link in docker logs
set -Eeuo pipefail

VM_DIR="${VM_DIR:-/var/lib/ubuntu-vm}"
# Guest RAM is intentionally fixed: exactly 256 MiB per VM. Not configurable.
readonly MEMORY_MIB=256
DISK_SIZE="${DISK_SIZE:-20G}"
GUEST_SWAP_MB="${GUEST_SWAP_MB:-1024}"        # swap file INSIDE the guest (disk, not RAM)
TCG_TB_SIZE_MB="${TCG_TB_SIZE_MB:-64}"        # TCG code cache in host RAM (QEMU default is 1 GiB)
BOOT_TIMEOUT_MIN="${BOOT_TIMEOUT_MIN:-90}"    # TCG is slow, so be generous
GUEST_UNIT_TIMEOUT_SEC="${GUEST_UNIT_TIMEOUT_SEC:-900}"  # systemd device/start timeouts in guest (default 90s is too short under TCG)
DIRECT_KERNEL="${DIRECT_KERNEL:-1}"           # 1 = boot kernel/initrd directly (needed to pass boot options)
GUEST_APPARMOR="${GUEST_APPARMOR:-1}"         # 0 = boot guest with apparmor=0 (much faster under TCG)
SHOW_BOOT_LOG="${SHOW_BOOT_LOG:-1}"           # 1 = stream VM console to docker logs
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

log() { printf '[qemu.sh] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

# ---- input validation --------------------------------------------------------
[[ -n "${MEMORY:-}" ]] && log "MEMORY=$MEMORY ignored: guest RAM is fixed at ${MEMORY_MIB}M"
for v in GUEST_SWAP_MB; do [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v must be a non-negative integer"; done
for v in TCG_TB_SIZE_MB BOOT_TIMEOUT_MIN GUEST_UNIT_TIMEOUT_SEC; do
  [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || die "$v must be a positive integer"
done
for v in DIRECT_KERNEL GUEST_APPARMOR SHOW_BOOT_LOG; do
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

for bin in wget sha256sum qemu-img cloud-localds qemu-system-x86_64; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool not found: $bin"
done

mkdir -p "$VM_DIR"

QEMU_PID=""; TAIL_PID=""
cleanup() {
  [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null || true
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    log "Stopping VM..."
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [[ -r /sys/fs/cgroup/memory.max ]]; then
  log "Container memory limit: $(cat /sys/fs/cgroup/memory.max) (needs ~512Mi+ for 256M guest + QEMU)"
fi

# ---- downloads ---------------------------------------------------------------
# fetch URL DEST: download atomically, verify against SHA256SUMS of its directory
fetch() {
  local url=$1 dest=$2 name sums
  name=${url##*/}
  log "Downloading $name..."
  rm -f "$dest.part"
  wget -q --show-progress --progress=dot:giga -O "$dest.part" "$url" || { rm -f "$dest.part"; return 1; }
  sums=$(wget -qO- "${url%/*}/SHA256SUMS" 2>/dev/null | grep -E "[ *]${name}\$" | awk '{print $1}' | head -n1 || true)
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
    log "WARNING: kernel/initrd download failed -> falling back to disk (GRUB) boot"
    rm -f "$KERNEL" "$INITRD"; DIRECT_KERNEL=0
  fi
fi
if [[ ! -f "$DISK_IMAGE" ]]; then
  log "Creating VM disk ($DISK_SIZE)..."
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK_IMAGE" "$DISK_SIZE"
fi

# ---- cloud-init (tuned for 256 MiB guests) -----------------------------------
# - no packages/package_update: apt update -> appstreamcli/apt-check -> OOM.
#   curl already ships in the Ubuntu server cloud image.
# - bootcmd (every boot, before anything heavy): swap file, mask heavy services,
#   persist longer systemd timeouts + nofail for /boot,/boot/efi (GRUB-boot path).
cat > "$VM_DIR/user-data" <<CLOUD
#cloud-config
hostname: ubuntu-sshx
package_update: false
package_upgrade: false
package_reboot_if_required: false
bootcmd:
  - [sh, -c, 'S=${GUEST_SWAP_MB}; if [ "\$S" -gt 0 ] && ! swapon --show=NAME --noheadings | grep -q /swapfile; then [ -f /swapfile ] || { fallocate -l \${S}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=\$S; chmod 600 /swapfile; mkswap /swapfile; }; swapon /swapfile; fi; sysctl -w vm.swappiness=60 >/dev/null; true']
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
        if command -v curl >/dev/null 2>&1; then
          curl -fsSL https://sshx.io/get | sh > /dev/ttyS0 2>&1 || sleep 5
        else
          wget -qO- https://sshx.io/get | sh > /dev/ttyS0 2>&1 || sleep 5
        fi
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
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --no-block, --now, sshx.service]
CLOUD
# new instance-id every start => cloud-init always re-applies the config
printf 'instance-id: sshx-%s\nlocal-hostname: ubuntu-sshx\n' "$(date +%s)" > "$VM_DIR/meta-data"
cloud-localds "$SEED_IMAGE" "$VM_DIR/user-data" "$VM_DIR/meta-data"

# ---- accelerator -------------------------------------------------------------
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  log "KVM detected -> hardware acceleration"
  ACCEL=(-accel kvm -cpu host)
else
  log "KVM not available -> TCG software emulation (slow, can take 10-40 min)"
  ACCEL=(-accel "tcg,thread=multi,tb-size=${TCG_TB_SIZE_MB}" -cpu qemu64)
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

# ---- boot --------------------------------------------------------------------
: > "$SERIAL_LOG"
log "Booting Ubuntu (guest RAM=${MEMORY_MIB}M, guest swap=${GUEST_SWAP_MB}M, CPUs=$CPUS)..."
qemu-system-x86_64 "${ACCEL[@]}" \
  -machine q35 -m "${MEMORY_MIB}M" -smp "$CPUS" \
  "${BOOT[@]}" \
  -drive "file=$DISK_IMAGE,if=virtio,format=qcow2" \
  -drive "file=$SEED_IMAGE,if=virtio,format=raw,readonly=on" \
  -nic user,model=virtio-net-pci \
  -device virtio-rng-pci \
  -vga none -display none -monitor none -no-reboot \
  -serial "file:$SERIAL_LOG" &
QEMU_PID=$!

if [[ "$SHOW_BOOT_LOG" == "1" ]]; then
  tail -n +1 -F "$SERIAL_LOG" 2>/dev/null \
    | sed -u -r 's/\x1B\[[0-9;?]*[A-Za-z]//g; s/\r//g; s/^/[vm] /' &
  TAIL_PID=$!
fi

# ---- wait for the sshx link --------------------------------------------------
URL=""; START=$(date +%s); LAST=0; OOM_WARNED=0
while [[ -z "$URL" ]]; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    RC=0; wait "$QEMU_PID" 2>/dev/null || RC=$?
    QEMU_PID=""
    log "QEMU exited unexpectedly (exit code $RC). Last console lines:"
    tail -n 50 "$SERIAL_LOG" || true
    exit 1
  fi
  URL=$(sed -r 's/\x1B\[[0-9;?]*[A-Za-z]//g' "$SERIAL_LOG" \
        | grep -a 'SSHX-OUT' \
        | grep -aoE 'https://sshx\.io/s/[A-Za-z0-9_-]+#[A-Za-z0-9_-]+' | tail -n 1 || true)
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
log "VM is running. Stop with: docker stop <container>"
RC=0; wait "$QEMU_PID" || RC=$?
QEMU_PID=""
log "QEMU exited (exit code $RC)"
exit "$RC"
