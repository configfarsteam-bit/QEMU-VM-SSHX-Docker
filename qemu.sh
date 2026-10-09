#!/usr/bin/env bash
# Ubuntu VM (QEMU, KVM if available, otherwise TCG) -> sshx -> link in docker logs
set -Eeuo pipefail

VM_DIR="${VM_DIR:-/var/lib/ubuntu-vm}"
# Guest RAM is intentionally fixed: exactly 256 MiB per VM. Not configurable.
readonly MEMORY_MIB=256
CPUS="${CPUS:-2}"
DISK_SIZE="${DISK_SIZE:-20G}"
GUEST_SWAP_MB="${GUEST_SWAP_MB:-1024}"        # swap file INSIDE the guest (disk, not RAM)
TCG_TB_SIZE_MB="${TCG_TB_SIZE_MB:-64}"        # TCG translation cache (host RAM), default would be 1 GiB
BOOT_TIMEOUT_MIN="${BOOT_TIMEOUT_MIN:-90}"    # TCG is slow, so be generous
SHOW_BOOT_LOG="${SHOW_BOOT_LOG:-1}"           # 1 = stream VM console to docker logs
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"

BASE_IMAGE="$VM_DIR/base.img"
DISK_IMAGE="$VM_DIR/disk.qcow2"
SEED_IMAGE="$VM_DIR/seed.iso"
SERIAL_LOG="$VM_DIR/serial.log"

log() { printf '[qemu.sh] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -n "${MEMORY:-}" ]] && log "MEMORY=$MEMORY ignored: guest RAM is fixed at ${MEMORY_MIB}M"
[[ "$CPUS" =~ ^[1-9][0-9]*$ ]]           || die "CPUS must be a positive integer"
[[ "$GUEST_SWAP_MB" =~ ^[0-9]+$ ]]       || die "GUEST_SWAP_MB must be an integer (0 = off)"
[[ "$TCG_TB_SIZE_MB" =~ ^[1-9][0-9]*$ ]] || die "TCG_TB_SIZE_MB must be a positive integer"
[[ "$BOOT_TIMEOUT_MIN" =~ ^[1-9][0-9]*$ ]] || die "BOOT_TIMEOUT_MIN must be a positive integer"

for bin in wget qemu-img cloud-localds qemu-system-x86_64; do
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

# Host-side info: show the container memory limit so OOMKills are easy to explain
if [[ -r /sys/fs/cgroup/memory.max ]]; then
  log "Container memory limit: $(cat /sys/fs/cgroup/memory.max)"
fi

# 1) Ubuntu image
if [[ ! -s "$BASE_IMAGE" ]]; then
  log "Downloading Ubuntu cloud image..."
  rm -f "$BASE_IMAGE.part"
  wget -q --show-progress --progress=dot:giga -O "$BASE_IMAGE.part" "$IMAGE_URL"
  mv "$BASE_IMAGE.part" "$BASE_IMAGE"
fi
if [[ ! -f "$DISK_IMAGE" ]]; then
  log "Creating VM disk ($DISK_SIZE)..."
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK_IMAGE" "$DISK_SIZE"
fi

# 2) cloud-init tuned for 256 MiB guests:
#    - NO packages:/package_update (they trigger apt update -> appstreamcli,
#      apt-check -> OOM). curl already ships in the Ubuntu server cloud image.
#    - bootcmd (runs first, every boot): add a swap file and stop heavy
#      services (snapd, apt timers, unattended-upgrades, motd/apt hooks).
cat > "$VM_DIR/user-data" <<CLOUD
#cloud-config
hostname: ubuntu-sshx
package_update: false
package_upgrade: false
package_reboot_if_required: false
bootcmd:
  - [sh, -c, 'S=${GUEST_SWAP_MB}; if [ "\$S" -gt 0 ] && ! swapon --show=NAME --noheadings | grep -q /swapfile; then [ -f /swapfile ] || { fallocate -l \${S}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=\$S; chmod 600 /swapfile; mkswap /swapfile; }; swapon /swapfile; fi; sysctl -w vm.swappiness=60 >/dev/null; true']
  - [sh, -c, 'for u in snapd.service snapd.socket snapd.seeded.service unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service motd-news.timer motd-news.service packagekit.service ModemManager.service udisks2.service multipathd.service multipathd.socket fwupd.service; do systemctl stop "\$u" 2>/dev/null; systemctl mask "\$u" 2>/dev/null; done; true']
  - [sh, -c, 'rm -f /etc/apt/apt.conf.d/50appstream /etc/apt/apt.conf.d/99update-notifier; chmod -x /etc/update-motd.d/50-motd-news /etc/update-motd.d/90-updates-available /etc/update-motd.d/91-release-upgrade 2>/dev/null; true']
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

# 3) KVM or TCG
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  log "KVM detected -> hardware acceleration"
  ACCEL=(-accel kvm -cpu host)
else
  log "KVM not available -> TCG software emulation (slow, can take 10-40 min)"
  # tb-size caps the TCG code cache (default 1 GiB of host memory)
  ACCEL=(-accel "tcg,thread=multi,tb-size=${TCG_TB_SIZE_MB}" -cpu qemu64)
fi

# 4) Boot
: > "$SERIAL_LOG"
log "Booting Ubuntu (guest RAM=${MEMORY_MIB}M, guest swap=${GUEST_SWAP_MB}M, CPUs=$CPUS)..."
qemu-system-x86_64 "${ACCEL[@]}" \
  -machine q35 -m "${MEMORY_MIB}M" -smp "$CPUS" \
  -drive "file=$DISK_IMAGE,if=virtio,format=qcow2" \
  -drive "file=$SEED_IMAGE,if=virtio,format=raw,readonly=on" \
  -nic user,model=virtio-net-pci \
  -vga none -display none -monitor none \
  -serial "file:$SERIAL_LOG" &
QEMU_PID=$!

if [[ "$SHOW_BOOT_LOG" == "1" ]]; then
  tail -n +1 -F "$SERIAL_LOG" 2>/dev/null \
    | sed -u -r 's/\x1B\[[0-9;?]*[A-Za-z]//g; s/\r//g; s/^/[vm] /' &
  TAIL_PID=$!
fi

# 5) Wait for the sshx link
URL=""; START=$(date +%s); LAST=0; LAST_OOM_WARN=0
while [[ -z "$URL" ]]; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    wait "$QEMU_PID" 2>/dev/null; RC=$?
    log "QEMU exited unexpectedly (exit code $RC). Last console lines:"
    tail -n 50 "$SERIAL_LOG" || true
    exit 1
  fi
  URL=$(sed -r 's/\x1B\[[0-9;?]*[A-Za-z]//g' "$SERIAL_LOG" \
        | grep -a 'SSHX-OUT' \
        | grep -aoE 'https://sshx\.io/s/[A-Za-z0-9_-]+#[A-Za-z0-9_-]+' | tail -n 1 || true)
  if grep -aq 'Out of memory: Killed process' "$SERIAL_LOG" 2>/dev/null && (( LAST_OOM_WARN == 0 )); then
    log "WARNING: guest OOM killer fired (see [vm] lines)"; LAST_OOM_WARN=1
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
wait "$QEMU_PID"
