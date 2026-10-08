#!/usr/bin/env bash
set -Eeuo pipefail

VM_DIR="${VM_DIR:-/var/lib/ubuntu-vm}"
BASE_IMAGE="$VM_DIR/ubuntu-24.04-server-cloudimg-amd64.img"
DISK_IMAGE="$VM_DIR/ubuntu.qcow2"
SEED_IMAGE="$VM_DIR/seed.iso"
SSH_KEY="$VM_DIR/id_ed25519"

SSH_PORT="${SSH_PORT:-2222}"
MEMORY="${MEMORY:-2048}"
CPUS="${CPUS:-2}"

log() {
    printf '[qemu.sh] %s
' "$*"
}

mkdir -p "$VM_DIR"

# جلوگیری از اجرای هم‌زمان دو VM روی یک volume
exec 9>"$VM_DIR/qemu.lock"

if ! flock -n 9; then
    log "Another instance is already using this VM volume"
    exit 1
fi

cleanup() {
    if [[ -n "${QEMU_PID:-}" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        log "Stopping virtual machine..."
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

# ساخت کلید SSH
if [[ ! -f "$SSH_KEY" ]]; then
    log "Generating SSH key..."
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" >/dev/null
fi

# دریافت آخرین Ubuntu 24.04 Cloud Image
if [[ ! -s "$BASE_IMAGE" ]]; then
    log "Downloading latest Ubuntu 24.04 cloud image..."

    wget -q --show-progress \
        -O "$BASE_IMAGE" \
        "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
fi

# ساخت دیسک VM
if [[ ! -f "$DISK_IMAGE" ]]; then
    log "Creating VM disk..."

    qemu-img create \
        -f qcow2 \
        -F qcow2 \
        -b "$BASE_IMAGE" \
        "$DISK_IMAGE" \
        20G >/dev/null
fi

PUBKEY="$(cat "$SSH_KEY.pub")"

# تنظیم cloud-init
cat > "$VM_DIR/user-data" <<EOF
#cloud-config

hostname: ubuntu-sshx
manage_etc_hosts: true

users:
  - name: ubuntu
    shell: /bin/bash
    groups:
      - sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $PUBKEY

ssh_pwauth: false
package_update: true

packages:
  - openssh-server
  - curl
  - ca-certificates

runcmd:
  - systemctl enable --now ssh
  - touch /var/lib/cloud/instance/sshx-ready
EOF

cat > "$VM_DIR/meta-data" <<EOF
instance-id: ubuntu-sshx
local-hostname: ubuntu-sshx
EOF

log "Creating cloud-init seed image..."

cloud-localds \
    "$SEED_IMAGE" \
    "$VM_DIR/user-data" \
    "$VM_DIR/meta-data"

# تشخیص KVM
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    log "KVM detected; using hardware acceleration"

    ACCEL_ARGS=(
        -enable-kvm
        -cpu host
    )
else
    log "KVM not detected; using QEMU software emulation"

    ACCEL_ARGS=(
        -accel tcg,thread=multi
        -cpu max
    )
fi

SERIAL_LOG="$VM_DIR/serial.log"
QEMU_ERROR_LOG="$VM_DIR/qemu.stderr.log"

: > "$SERIAL_LOG"
: > "$QEMU_ERROR_LOG"

log "Starting Ubuntu virtual machine..."

qemu-system-x86_64 \
    "${ACCEL_ARGS[@]}" \
    -machine q35 \
    -m "$MEMORY" \
    -smp "$CPUS" \
    -name ubuntu-sshx \
    -drive "file=$DISK_IMAGE,if=virtio,format=qcow2" \
    -drive "file=$SEED_IMAGE,if=virtio,format=raw,readonly=on" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
    -display none \
    -serial "file:$SERIAL_LOG" \
    -monitor none \
    -no-reboot \
    -no-shutdown \
    >"$QEMU_ERROR_LOG" 2>&1 &

QEMU_PID=$!

sleep 2

if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    log "QEMU failed to start"
    log "QEMU error log:"
    cat "$QEMU_ERROR_LOG" 2>/dev/null || true
    log "VM serial log:"
    cat "$SERIAL_LOG" 2>/dev/null || true
    exit 1
fi

log "Waiting for Ubuntu SSH on 127.0.0.1:$SSH_PORT..."

READY=0

for _ in {1..180}; do
    if ssh \
        -p "$SSH_PORT" \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=3 \
        ubuntu@127.0.0.1 \
        "test -f /var/lib/cloud/instance/sshx-ready" \
        >/dev/null 2>&1; then

        READY=1
        break
    fi

    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        log "QEMU stopped unexpectedly"

        log "QEMU error log:"
        cat "$QEMU_ERROR_LOG" 2>/dev/null || true

        log "VM serial log:"
        cat "$SERIAL_LOG" 2>/dev/null || true

        exit 1
    fi

    sleep 2
done

if (( READY != 1 )); then
    log "Ubuntu did not become ready within 6 minutes"
    exit 1
fi

log "Ubuntu is ready"
log "Starting sshx inside the virtual machine"

printf '
'
printf '%s
' '============================================================'
printf '%s
' '                 SSHX LINK, COPY THIS URL'
printf '%s
' '============================================================'
printf '
'

ssh -tt \
    -p "$SSH_PORT" \
    -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ubuntu@127.0.0.1 \
    'bash -lc '\''
        export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

        if ! command -v sshx >/dev/null 2>&1; then
            curl -sSf https://sshx.io/get | sh
        fi

        export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

        exec sshx
    '\'''
