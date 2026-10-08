#!/usr/bin/env bash
set -Eeuo pipefail

VM_DIR="${VM_DIR:-/var/lib/ubuntu-vm}"
BASE_IMAGE="$VM_DIR/ubuntu-cloud.img"
DISK_IMAGE="$VM_DIR/ubuntu.qcow2"
SEED_IMAGE="$VM_DIR/seed.iso"
SSH_KEY="$VM_DIR/id_ed25519"
SSH_PORT=2222

MEMORY="${MEMORY:-2048}"
CPUS="${CPUS:-2}"

mkdir -p "$VM_DIR"

log() {
    echo "[qemu.sh] $*"
}

cleanup() {
    log "Stopping virtual machine..."

    if [[ -n "${QEMU_PID:-}" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

# ساخت کلید SSH
if [[ ! -f "$SSH_KEY" ]]; then
    log "Generating SSH key..."
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY"
fi

# دریافت جدیدترین Ubuntu 24.04 Cloud Image
if [[ ! -f "$BASE_IMAGE" ]]; then
    log "Downloading latest Ubuntu cloud image..."

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
        20G
fi

# تنظیمات cloud-init
cat > "$VM_DIR/user-data" <<EOF
#cloud-config

hostname: ubuntu-sshx
manage_etc_hosts: true

users:
  - name: ubuntu
    shell: /bin/bash
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$SSH_KEY.pub")

ssh_pwauth: false
package_update: true

packages:
  - openssh-server
  - curl
  - ca-certificates
  - bash

runcmd:
  - systemctl enable ssh
  - systemctl restart ssh
  - touch /var/lib/cloud/instance/ssh-ready
EOF

cat > "$VM_DIR/meta-data" <<EOF
instance-id: ubuntu-sshx
local-hostname: ubuntu-sshx
EOF

cloud-localds \
    "$SEED_IMAGE" \
    "$VM_DIR/user-data" \
    "$VM_DIR/meta-data"

# تشخیص KVM
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    log "KVM detected"
    log "Using hardware virtualization"

    ACCEL_ARGS=(
        -enable-kvm
        -cpu host
    )
else
    log "KVM not detected"
    log "Using QEMU software emulation"

    ACCEL_ARGS=(
        -accel tcg
        -cpu max
    )
fi

log "Starting Ubuntu virtual machine..."

qemu-system-x86_64 \
    "${ACCEL_ARGS[@]}" \
    -machine q35 \
    -m "$MEMORY" \
    -smp "$CPUS" \
    -name ubuntu-sshx \
    -drive "file=$DISK_IMAGE,if=virtio,format=qcow2" \
    -drive "file=$SEED_IMAGE,if=virtio,format=raw,readonly=on" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -serial "$VM_DIR/serial.log" \
    >/dev/null 2>&1 &

QEMU_PID=$!

log "Waiting for SSH inside Ubuntu..."

SSH_READY=false

for _ in {1..180}; do
    if ssh \
        -p "$SSH_PORT" \
        -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=3 \
        ubuntu@127.0.0.1 \
        "test -f /var/lib/cloud/instance/ssh-ready" \
        >/dev/null 2>&1; then

        SSH_READY=true
        break
    fi

    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        log "QEMU stopped unexpectedly"
        cat "$VM_DIR/serial.log" || true
        exit 1
    fi

    sleep 2
done

if [[ "$SSH_READY" != "true" ]]; then
    log "Ubuntu did not become ready in time"
    exit 1
fi

log "Ubuntu is ready"
log "Installing sshx inside the virtual machine..."

echo
echo "============================================================"
echo "                 SSHX STARTING"
echo "============================================================"
echo

ssh -tt \
    -p "$SSH_PORT" \
    -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ubuntu@127.0.0.1 \
    'bash -lc "
        export PATH=\$HOME/.local/bin:\$HOME/bin:\$PATH

        if ! command -v sshx >/dev/null 2>&1; then
            curl -sSf https://sshx.io/get | sh
        fi

        export PATH=\$HOME/.local/bin:\$HOME/bin:\$PATH

        echo
        echo \"============================================================\"
        echo \"                    SSHX LINK\"
        echo \"============================================================\"

        sshx

        echo
        echo \"============================================================\"
        echo \"                    SSHX STOPPED\"
        echo \"============================================================\"
    "'
