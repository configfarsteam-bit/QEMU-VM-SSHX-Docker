#!/usr/bin/env bash
# Ubuntu VM (QEMU, KVM if available, otherwise TCG) -> sshx -> link in docker logs
set -Eeuo pipefail

VM_DIR="${VM_DIR:-/var/lib/ubuntu-vm}"
# Guest RAM is intentionally fixed. Do not make this configurable: the
# deployment contract is exactly 256 MiB per VM.
readonly MEMORY_MIB=256
CPUS="${CPUS:-2}"
DISK_SIZE="${DISK_SIZE:-20G}"
BOOT_TIMEOUT_MIN="${BOOT_TIMEOUT_MIN:-90}"   # TCG is slow, so be generous
SHOW_BOOT_LOG="${SHOW_BOOT_LOG:-1}"           # 1 = stream VM console to docker logs
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"

BASE_IMAGE="$VM_DIR/base.img"
DISK_IMAGE="$VM_DIR/disk.qcow2"
SEED_IMAGE="$VM_DIR/seed.iso"
SERIAL_LOG="$VM_DIR/serial.log"

log() { printf '[qemu.sh] %s\n' "$*"; }

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

# 1) Ubuntu image
if [[ ! -s "$BASE_IMAGE" ]]; then
  log "Downloading Ubuntu cloud image..."
  wget -q --show-progress --progress=dot:giga -O "$BASE_IMAGE.part" "$IMAGE_URL"
  mv "$BASE_IMAGE.part" "$BASE_IMAGE"
fi
if [[ ! -f "$DISK_IMAGE" ]]; then
  log "Creating VM disk ($DISK_SIZE)..."
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK_IMAGE" "$DISK_SIZE"
fi

# 2) cloud-init: no apt update (very slow under TCG), sshx runs as a systemd
#    service and writes its output to the serial console (ttyS0)
cat > "$VM_DIR/user-data" <<'CLOUD'
#cloud-config
hostname: ubuntu-sshx
package_update: false
package_upgrade: false
packages:
  - curl
write_files:
  - path: /usr/local/bin/run-sshx.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      export HOME=/root SHELL=/bin/bash TERM=xterm-256color
      export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      until command -v sshx >/dev/null 2>&1; do
        echo "SSHX-INFO: installing sshx..." > /dev/ttyS0
        curl -fsSL https://sshx.io/get | sh > /dev/ttyS0 2>&1 || sleep 5
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
      [Install]
      WantedBy=multi-user.target
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, --no-block, sshx.service]
CLOUD
# new instance-id every start => cloud-init always re-applies the config
printf 'instance-id: sshx-%s
local-hostname: ubuntu-sshx
' "$(date +%s)" > "$VM_DIR/meta-data"
cloud-localds "$SEED_IMAGE" "$VM_DIR/user-data" "$VM_DIR/meta-data"

# 3) KVM or TCG
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  log "KVM detected -> hardware acceleration"
  ACCEL=(-accel kvm -cpu host)
else
  log "KVM not available -> TCG software emulation (slow, can take 10-40 min)"
  ACCEL=(-accel tcg,thread=multi -cpu qemu64)
fi

# 4) Boot
: > "$SERIAL_LOG"
log "Booting Ubuntu (RAM=${MEMORY_MIB}M CPUs=$CPUS)..."
qemu-system-x86_64 "${ACCEL[@]}" \
  -machine q35 -m "${MEMORY_MIB}M" -smp "$CPUS" \
  -drive "file=$DISK_IMAGE,if=virtio,format=qcow2" \
  -drive "file=$SEED_IMAGE,if=virtio,format=raw,readonly=on" \
  -nic user,model=virtio-net-pci \
  -display none -monitor none \
  -serial "file:$SERIAL_LOG" &
QEMU_PID=$!

if [[ "$SHOW_BOOT_LOG" == "1" ]]; then
  tail -n +1 -F "$SERIAL_LOG" 2>/dev/null \
    | sed -u -r 's/\x1B\[[0-9;?]*[A-Za-z]//g; s/\r//g; s/^/[vm] /' &
  TAIL_PID=$!
fi

# 5) Wait for the sshx link
URL=""; START=$(date +%s); LAST=0
while [[ -z "$URL" ]]; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    log "QEMU exited unexpectedly. Last console lines:"
    tail -n 50 "$SERIAL_LOG" || true
    exit 1
  fi
  URL=$(sed -r 's/\x1B\[[0-9;?]*[A-Za-z]//g' "$SERIAL_LOG" \
        | grep -a 'SSHX-OUT' \
        | grep -aoE 'https://sshx\.io/s/[A-Za-z0-9_-]+#[A-Za-z0-9_-]+' | tail -n 1 || true)
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
printf '
==================== SSHX LINK ====================
'
printf '%s
' "$URL"
printf '===================================================

'
log "VM is running. Stop with: docker stop <container>"
wait "$QEMU_PID"
