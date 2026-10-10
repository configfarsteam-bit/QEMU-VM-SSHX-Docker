#!/usr/bin/env bash
# Run an amd64 Ubuntu cloud VM with QEMU, then print an sshx link.
# Designed for an unprivileged Docker container and blitz.cloud Free.
set -Eeuo pipefail
umask 077

STATE_DIR="${STATE_DIR:-${VM_DIR:-/state/ubuntu-vm}}"
readonly MEMORY_MIB=256
DISK_SIZE="${DISK_SIZE:-20G}"
GUEST_SWAP_MB="${GUEST_SWAP_MB:-1024}"
TCG_TB_SIZE_MB="${TCG_TB_SIZE_MB:-32}"
BOOT_TIMEOUT_MIN="${BOOT_TIMEOUT_MIN:-90}"
GUEST_UNIT_TIMEOUT_SEC="${GUEST_UNIT_TIMEOUT_SEC:-900}"
CPUS="${CPUS:-1}"
SHOW_BOOT_LOG="${SHOW_BOOT_LOG:-1}"
IMAGE_BASE_URL="${IMAGE_BASE_URL:-https://cloud-images.ubuntu.com/noble/current}"
IMAGE_NAME="noble-server-cloudimg-amd64"
IMAGE_URL="${IMAGE_URL:-$IMAGE_BASE_URL/$IMAGE_NAME.img}"
KERNEL_URL="${KERNEL_URL:-$IMAGE_BASE_URL/unpacked/$IMAGE_NAME-vmlinuz-generic}"
INITRD_URL="${INITRD_URL:-$IMAGE_BASE_URL/unpacked/$IMAGE_NAME-initrd-generic}"

BASE_IMAGE="$STATE_DIR/base.img"
KERNEL="$STATE_DIR/vmlinuz"
INITRD="$STATE_DIR/initrd"
DISK_IMAGE="$STATE_DIR/disk.qcow2"
SEED_IMAGE="$STATE_DIR/seed.iso"
SERIAL_LOG="$STATE_DIR/serial.log"
LOCK_DIR="$STATE_DIR/.lock"
QEMU_PID=""
TAIL_PID=""

log() { printf '[qemu.sh] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
cleanup() {
  [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null || true
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    log 'Stopping VM...'
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

[[ "$GUEST_SWAP_MB" =~ ^[0-9]+$ ]] || die 'GUEST_SWAP_MB must be a non-negative integer'
[[ "$TCG_TB_SIZE_MB" =~ ^[1-9][0-9]*$ ]] || die 'TCG_TB_SIZE_MB must be positive'
[[ "$BOOT_TIMEOUT_MIN" =~ ^[1-9][0-9]*$ ]] || die 'BOOT_TIMEOUT_MIN must be positive'
[[ "$GUEST_UNIT_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || die 'GUEST_UNIT_TIMEOUT_SEC must be positive'
[[ "$CPUS" =~ ^[1-9]$ ]] || die 'CPUS must be 1..9'
[[ "$SHOW_BOOT_LOG" == 0 || "$SHOW_BOOT_LOG" == 1 ]] || die 'SHOW_BOOT_LOG must be 0 or 1'
[[ "$DISK_SIZE" =~ ^[1-9][0-9]*[KMG]$ ]] || die 'DISK_SIZE must look like 20G, 512M, or 4096K'

for bin in wget sha256sum qemu-img cloud-localds qemu-system-x86_64; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool not found: $bin"
done
mkdir -p "$STATE_DIR" || die "cannot create STATE_DIR=$STATE_DIR"
[[ -w "$STATE_DIR" ]] || die "STATE_DIR is not writable: $STATE_DIR"
mkdir "$LOCK_DIR" 2>/dev/null || die "another VM is already using $STATE_DIR"

if [[ -r /sys/fs/cgroup/memory.max ]]; then
  limit=$(cat /sys/fs/cgroup/memory.max)
  if [[ "$limit" =~ ^[0-9]+$ ]]; then
    mib=$((limit / 1024 / 1024))
    log "Container memory limit: ${mib} MiB; QEMU may need close to 512 MiB with a 256 MiB guest"
    (( mib < 384 )) && die 'container memory limit is too small for a 256 MiB QEMU guest'
  fi
fi

fetch() {
  local url="$1" dest="$2" name sums got
  name="${url##*/}"
  log "Downloading $name..."
  rm -f "$dest.part"
  wget -q --show-progress --progress=dot:giga --tries=3 --timeout=30 -O "$dest.part" "$url" || {
    rm -f "$dest.part"; return 1;
  }
  sums=$(wget -qO- --tries=3 --timeout=30 "${url%/*}/SHA256SUMS" 2>/dev/null \
    | awk -v n="$name" '$NF == n { print $1; exit }' || true)
  [[ "$sums" =~ ^[0-9a-fA-F]{64}$ ]] || { rm -f "$dest.part"; die "no valid SHA256 entry for $name"; }
  got=$(sha256sum "$dest.part" | awk '{print $1}')
  [[ "$got" == "$sums" ]] || { rm -f "$dest.part"; die "checksum mismatch for $name"; }
  mv -f "$dest.part" "$dest"
  log "$name checksum OK"
}

# The kernel, initrd, and base image must come from one Ubuntu build.
if [[ ! -s "$BASE_IMAGE" || ! -s "$KERNEL" || ! -s "$INITRD" ]]; then
  rm -f "$BASE_IMAGE" "$KERNEL" "$INITRD" "$DISK_IMAGE"
  fetch "$IMAGE_URL" "$BASE_IMAGE" || die 'base image download failed'
  fetch "$KERNEL_URL" "$KERNEL" || die 'kernel download failed'
  fetch "$INITRD_URL" "$INITRD" || die 'initrd download failed'
fi
if [[ ! -f "$DISK_IMAGE" ]]; then
  log "Creating VM disk ($DISK_SIZE)..."
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK_IMAGE" "$DISK_SIZE"
fi

cat > "$STATE_DIR/user-data" <<CLOUD
#cloud-config
hostname: ubuntu-sshx
package_update: false
package_upgrade: false
package_reboot_if_required: false
bootcmd:
  - [sh, -c, 'S=${GUEST_SWAP_MB}; if [ "\$S" -gt 0 ] && ! swapon --show=NAME --noheadings | grep -q /swapfile; then [ -f /swapfile ] || { fallocate -l \${S}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=\$S; chmod 600 /swapfile; mkswap /swapfile; }; swapon /swapfile; fi; true']
  - [sh, -c, 'for u in snapd.service snapd.socket snapd.seeded.service unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service motd-news.timer motd-news.service man-db.timer fwupd-refresh.timer packagekit.service ModemManager.service udisks2.service multipathd.service multipathd.socket fwupd.service; do systemctl --no-block stop "\$u" 2>/dev/null; systemctl mask "\$u" 2>/dev/null; done; true']
  - [sh, -c, 'mkdir -p /etc/systemd/system.conf.d; printf "[Manager]\\nDefaultTimeoutStartSec=${GUEST_UNIT_TIMEOUT_SEC}s\\nDefaultDeviceTimeoutSec=${GUEST_UNIT_TIMEOUT_SEC}s\\n" > /etc/systemd/system.conf.d/90-slow-qemu.conf; true']
write_files:
  - path: /usr/local/bin/run-sshx.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -u
      export HOME=/root SHELL=/bin/bash TERM=xterm-256color
      export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      until command -v sshx >/dev/null 2>&1; do
        echo 'SSHX-INFO: installing sshx...' > /dev/ttyS0
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 120 https://sshx.io/get | sh > /dev/ttyS0 2>&1 || sleep 5
      done
      echo 'SSHX-INFO: starting sshx' > /dev/ttyS0
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
      [Install]
      WantedBy=multi-user.target
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, sshx.service]
CLOUD
printf 'instance-id: sshx-%s\nlocal-hostname: ubuntu-sshx\n' "$(date +%s%N)" > "$STATE_DIR/meta-data"
cloud-localds "$SEED_IMAGE" "$STATE_DIR/user-data" "$STATE_DIR/meta-data"

if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  log 'KVM detected; using hardware acceleration'
  ACCEL=(-accel kvm -cpu host)
else
  log 'KVM unavailable; using QEMU TCG software emulation'
  ACCEL=(-accel "tcg,thread=single,tb-size=${TCG_TB_SIZE_MB}" -cpu qemu64)
fi
CMDLINE="root=LABEL=cloudimg-rootfs ro console=ttyS0,115200n8 ds=nocloud systemd.default_device_timeout_sec=${GUEST_UNIT_TIMEOUT_SEC} systemd.default_timeout_start_sec=${GUEST_UNIT_TIMEOUT_SEC}"
for u in snapd.service snapd.socket snapd.seeded.service unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service motd-news.timer man-db.timer fwupd-refresh.timer ModemManager.service multipathd.service multipathd.socket udisks2.service packagekit.service; do CMDLINE+=" systemd.mask=$u"; done
: > "$SERIAL_LOG"
log "Booting Ubuntu (guest RAM=${MEMORY_MIB}M, swap=${GUEST_SWAP_MB}M, CPUs=$CPUS)..."
qemu-system-x86_64 "${ACCEL[@]}" -machine q35 -m "${MEMORY_MIB}M" -smp "$CPUS" \
  -kernel "$KERNEL" -initrd "$INITRD" -append "$CMDLINE" \
  -drive "file=$DISK_IMAGE,if=virtio,format=qcow2,cache=writeback,aio=threads" \
  -drive "file=$SEED_IMAGE,if=virtio,format=raw,readonly=on" \
  -nic user,model=virtio-net-pci -device virtio-rng-pci -vga none -display none -monitor none -no-reboot -serial "file:$SERIAL_LOG" &
QEMU_PID=$!
if [[ "$SHOW_BOOT_LOG" == 1 ]]; then
  tail -n +1 -F "$SERIAL_LOG" 2>/dev/null | sed -u -r 's/\x1B\[[0-9;?]*[A-Za-z]//g; s/\r//g; s/^/[vm] /' &
  TAIL_PID=$!
fi

URL=''; start=$(date +%s); last=0
while [[ -z "$URL" ]]; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    rc=0; wait "$QEMU_PID" 2>/dev/null || rc=$?
    QEMU_PID=''; tail -n 80 "$SERIAL_LOG" || true
    die "QEMU exited before an sshx link was found (exit $rc)"
  fi
  URL=$(grep -aohE 'https://sshx\.io/s/[A-Za-z0-9_-]+(#[A-Za-z0-9_-]+)?' "$SERIAL_LOG" | tail -n1 || true)
  elapsed=$(( ($(date +%s) - start) / 60 ))
  if (( elapsed >= BOOT_TIMEOUT_MIN )); then
    tail -n 80 "$SERIAL_LOG" || true
    die "no sshx link after ${BOOT_TIMEOUT_MIN} minutes"
  fi
  if (( elapsed > last )); then last=$elapsed; log "still booting... ${elapsed} min"; fi
  [[ -z "$URL" ]] && sleep 5
done
[[ -n "$TAIL_PID" ]] && { kill "$TAIL_PID" 2>/dev/null || true; TAIL_PID=''; }
printf '\n==================== SSHX LINK ====================\n%s\n===================================================\n' "$URL"
log 'VM is running. Stop the container to stop the VM.'
wait "$QEMU_PID"
