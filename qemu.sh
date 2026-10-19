#!/usr/bin/env bash
# Ubuntu VM (QEMU; KVM if available, otherwise TCG)
#   -> password protected web terminal (ttyd)
#   -> public https link (cloudflared quick tunnel), printed in the docker logs.
#
# Usage:   PAS='a-long-secret-password' ./qemu.sh        (PAS is required)
#
# How it works
# - ttyd and cloudflared run in the CONTAINER (not inside the VM). ttyd serves a web terminal on
#   $PORT (default 8080); every browser tab runs an ssh session into the VM through a QEMU port
#   forward on 127.0.0.1:$SSH_PORT. cloudflared exposes the ttyd port as https://<random>.trycloudflare.com.
#   Login in the browser: user $WEB_USER (default "admin") + the password from PAS.
# - The guest is only reachable through that forward, with a key pair generated in $VM_DIR.
# - CPU count, guest RAM and disk size are detected from the container (see "auto sizing" below).
#
# Auto sizing (every value can still be forced with the env var of the same name)
# - CPUS         = CPUs the container may really use (cpuset + cgroup quota), no artificial cap
# - MEMORY_MIB   = container RAM limit - TCG code cache - host reserve  (always BELOW the limit)
# - DISK_SIZE    = free space of the volume holding $VM_DIR (minus room for the snapshots);
#                  applied when the disk is created (a qcow2 with snapshots cannot be resized)
#
# Sleep/restart survival: while the VM runs, a live snapshot (RAM + disk state) is saved into
# /state every SNAPSHOT_INTERVAL_MIN minutes. If the container is stopped and started again with
# the SAME /state volume, the VM is restored from that snapshot instead of being rebuilt.
# (The tunnel link is NOT part of the snapshot: every container start gets a new link.)
#
# Notes on semantics (by design of QEMU internal snapshots):
# - Restoring a snapshot also rolls the DISK back to the moment of the snapshot.
# - If the guest shuts down / reboots by itself (QEMU exits with code 0) the snapshot is
#   discarded, so the next start cold-boots from the (up to date) disk.
# - If CPU count or RAM size differ from the run that made the snapshot, it cannot be loaded and
#   the script falls back to a cold boot from the disk (data is kept).
set -Eeuo pipefail
export LC_ALL=C

log() { printf '[qemu.sh] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  die "bash >= 4.4 is required"
fi

# ---- settings -----------------------------------------------------------------
VM_DIR="${VM_DIR:-/state/ubuntu-vm}"
PAS="${PAS:-}"                                # web terminal password (required)
WEB_USER="${WEB_USER:-admin}"                 # web terminal user name
WEB_PORT="${PORT:-8080}"                      # ttyd listens here (also the port the platform should expose)
WEB_BIND="${WEB_BIND:-0.0.0.0}"               # use 127.0.0.1 if only the tunnel should reach ttyd
WEB_MAX_CLIENTS="${WEB_MAX_CLIENTS:-4}"       # max browser tabs at the same time
SSH_PORT="${SSH_PORT:-2222}"                  # 127.0.0.1 port forwarded to the guest's sshd
GUEST_ROOT_SHELL="${GUEST_ROOT_SHELL:-1}"     # 1 = web terminal opens a root shell (sudo -i), 0 = plain "ubuntu" shell
CF_PROTOCOL="${CF_PROTOCOL:-http2}"           # cloudflared transport: http2 (TCP, works almost everywhere), quic or auto
CF_WAIT_SEC="${CF_WAIT_SEC:-60}"              # how long to wait for the first tunnel link before booting the VM
MEMORY_MIB="${MEMORY_MIB:-auto}"              # guest RAM in MiB
CPUS="${CPUS:-auto}"                          # guest vCPUs
DISK_SIZE="${DISK_SIZE:-auto}"                # guest disk (virtual size)
GUEST_SWAP_MB="${GUEST_SWAP_MB:-auto}"        # swap file INSIDE the guest (disk, not RAM); auto = min(1024, disk/8)
TCG_TB_SIZE_MB="${TCG_TB_SIZE_MB:-auto}"      # TCG code cache in host RAM; auto = 12% of the container RAM (48..256)
HOST_RESERVE_MIB="${HOST_RESERVE_MIB:-auto}"  # QEMU overhead + ttyd + cloudflared + ssh/python helpers + page cache; auto = 20% (160..1024)
CPU_MODEL="${CPU_MODEL:-qemu64}"              # TCG CPU model; qemu64 is much cheaper to emulate than "max"
MACHINE="${MACHINE:-pc,hpet=off}"             # i440fx is lighter than q35; no HPET = fewer timer exits
DISK_CACHE="${DISK_CACHE:-unsafe}"            # unsafe = fastest; use "none" if the container still gets OOM-killed
BOOT_TIMEOUT_MIN="${BOOT_TIMEOUT_MIN:-90}"    # TCG is slow, so be generous
GUEST_UNIT_TIMEOUT_SEC="${GUEST_UNIT_TIMEOUT_SEC:-900}"  # systemd device/start timeouts in guest (default 90s is too short under TCG)
DIRECT_KERNEL="${DIRECT_KERNEL:-1}"           # 1 = boot kernel/initrd directly (needed to pass boot options)
GUEST_APPARMOR="${GUEST_APPARMOR:-0}"         # 0 = boot guest with apparmor=0 (only used when FULL_VM=0)
FULL_VM="${FULL_VM:-1}"                       # 1 = behave like a normal full Ubuntu: no masked services, AppArmor on, full boot messages
DISABLE_FLOPPY="${DISABLE_FLOPPY:-1}"         # 1 = no virtual floppy drive (fixes "I/O error, dev fd0, sector 0" spam)
SHOW_BOOT_LOG="${SHOW_BOOT_LOG:-1}"           # 1 = stream VM console to docker logs until the VM is reachable
RESUME="${RESUME:-1}"                         # 1 = restore the VM from the last snapshot if one exists
SNAPSHOT_INTERVAL_MIN="${SNAPSHOT_INTERVAL_MIN:-20}"     # 0 = never snapshot (no resume possible); the VM is paused during each snapshot
SNAPSHOT_FIRST_DELAY_SEC="${SNAPSHOT_FIRST_DELAY_SEC:-300}"  # first snapshot this long after the VM became reachable
SNAPSHOT_TIMEOUT_SEC="${SNAPSHOT_TIMEOUT_SEC:-600}"      # give up on one periodic snapshot after this long
SNAPSHOT_STOP_TIMEOUT_SEC="${SNAPSHOT_STOP_TIMEOUT_SEC:-20}"  # best-effort snapshot on docker stop (0 = skip); raise it together with "docker stop -t"
RESUME_TIMEOUT_SEC="${RESUME_TIMEOUT_SEC:-180}"          # max wait for a restored VM to start running
IMAGE_BASE_URL="${IMAGE_BASE_URL:-https://cloud-images.ubuntu.com/noble/current}"
IMAGE_NAME="noble-server-cloudimg-amd64"
IMAGE_URL="${IMAGE_URL:-$IMAGE_BASE_URL/$IMAGE_NAME.img}"
KERNEL_URL="${KERNEL_URL:-$IMAGE_BASE_URL/unpacked/$IMAGE_NAME-vmlinuz-generic}"
INITRD_URL="${INITRD_URL:-$IMAGE_BASE_URL/unpacked/$IMAGE_NAME-initrd-generic}"
GUEST_USER="ubuntu"                           # default user of the Ubuntu cloud image

LOCK_HELD=0
MAIN_PID=$$
QEMU_PID=""; TAIL_PID=""; SNAP_PID=""; WEB_PID=""; TUN_PID=""; SNAP_READY=0
RESUME_TAG=""; RESUMED=0
TTYD_BIN=""; CF_BIN=""

# ---- input validation --------------------------------------------------------
# (no leading zeros: "08" would be read as an invalid octal number inside (( )))
for v in SNAPSHOT_INTERVAL_MIN SNAPSHOT_STOP_TIMEOUT_SEC; do
  [[ "${!v}" =~ ^(0|[1-9][0-9]*)$ ]] || die "$v must be a non-negative integer (no leading zeros)"
done
[[ "$GUEST_SWAP_MB" == auto || "$GUEST_SWAP_MB" =~ ^(0|[1-9][0-9]*)$ ]] || die "GUEST_SWAP_MB must be 'auto' or a non-negative integer"
for v in BOOT_TIMEOUT_MIN GUEST_UNIT_TIMEOUT_SEC SNAPSHOT_FIRST_DELAY_SEC SNAPSHOT_TIMEOUT_SEC \
         RESUME_TIMEOUT_SEC WEB_MAX_CLIENTS CF_WAIT_SEC; do
  [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || die "$v must be a positive integer"
done
for v in MEMORY_MIB CPUS TCG_TB_SIZE_MB HOST_RESERVE_MIB; do
  [[ "${!v}" == auto || "${!v}" =~ ^[1-9][0-9]*$ ]] || die "$v must be 'auto' or a positive integer"
done
for v in DIRECT_KERNEL GUEST_APPARMOR SHOW_BOOT_LOG RESUME FULL_VM DISABLE_FLOPPY GUEST_ROOT_SHELL; do
  [[ "${!v}" == 0 || "${!v}" == 1 ]] || die "$v must be 0 or 1"
done
[[ "$DISK_CACHE" =~ ^(unsafe|writeback|none|writethrough)$ ]] || die "DISK_CACHE must be unsafe, writeback, none or writethrough"
[[ "$DISK_SIZE" == auto || "$DISK_SIZE" =~ ^[1-9][0-9]*[KkMmGgTt]?$ ]] || die "DISK_SIZE must be 'auto' or look like 20G, 512M or a plain byte count"
[[ "$CPU_MODEL" =~ ^[A-Za-z0-9_.,+-]+$ ]] || die "CPU_MODEL contains invalid characters"
[[ "$MACHINE" =~ ^[A-Za-z0-9_.,=-]+$ ]] || die "MACHINE contains invalid characters"
[[ "$CF_PROTOCOL" =~ ^(auto|http2|quic)$ ]] || die "CF_PROTOCOL must be auto, http2 or quic"
[[ "$WEB_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "WEB_USER may only contain letters, digits, '.', '_' and '-'"
[[ "$WEB_BIND" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "WEB_BIND must be an IPv4 address (0.0.0.0 = all interfaces, 127.0.0.1 = only the tunnel)"
if [[ "$WEB_BIND" == 0.0.0.0 ]]; then WEB_HOST=127.0.0.1; else WEB_HOST=$WEB_BIND; fi
{ [[ "$WEB_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( WEB_PORT <= 65535 )); } || die "PORT must be an integer from 1 to 65535"
{ [[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( SSH_PORT <= 65535 )); } || die "SSH_PORT must be an integer from 1 to 65535"
(( SSH_PORT != WEB_PORT )) || die "SSH_PORT and PORT must differ"

# ---- web terminal password -----------------------------------------------------
[[ -n "$PAS" ]] || die "PAS is empty. Set the web terminal password, e.g.  PAS='a-long-secret' ./qemu.sh"
[[ "$PAS" != *$'\n'* && "$PAS" != *$'\r'* ]] || die "PAS must not contain line breaks"
if (( ${#PAS} < 8 )); then
  log "WARNING: PAS is shorter than 8 characters; the terminal will be reachable from the internet, use a long password"
fi
WEB_PASS=$PAS
unset PAS            # do not hand the password to QEMU / cloudflared / the guest via the environment

# ---- host tools ----------------------------------------------------------------
for bin in wget sha256sum qemu-img cloud-localds qemu-system-x86_64 python3 pgrep flock \
           ssh ssh-keygen df awk sed grep head tail tr cut getent id; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool not found: $bin"
done

if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
  die "uid $(id -u) has no /etc/passwd entry; ssh refuses to run without one. Run the container as root or add the user"
fi
mkdir -p "$VM_DIR"
[[ -w "$VM_DIR" ]] || die "VM_DIR is not writable: $VM_DIR"
# absolute path: the qcow2 overlay stores its backing file path, a relative VM_DIR would break it
VM_DIR=$(cd "$VM_DIR" && pwd -P)

BASE_IMAGE="$VM_DIR/base.img"
KERNEL="$VM_DIR/vmlinuz"
INITRD="$VM_DIR/initrd"
DISK_IMAGE="$VM_DIR/disk.qcow2"
SEED_IMAGE="$VM_DIR/seed.iso"
SERIAL_LOG="$VM_DIR/serial.log"
SNAP_FILE="$VM_DIR/snapshot-tag"        # snapshot tag of the last good snapshot
MON_SOCK="$VM_DIR/monitor.sock"
LOCK_FILE="$VM_DIR/.vm.lock"
SSH_KEY="$VM_DIR/ssh_key"               # key pair used by the web terminal to log into the guest
READY_MARK="$VM_DIR/.web-shell-ready"   # exists once this script version reached the guest with SSH_KEY
WEB_SHELL="$VM_DIR/web-shell.sh"        # command that ttyd runs for every browser tab
TUNNEL_URL_FILE="$VM_DIR/tunnel-url"
CF_LOG="$VM_DIR/cloudflared.log"
SSH_PROBE_LOG="$VM_DIR/ssh-probe.log"
BIN_DIR="$VM_DIR/bin"
(( ${#MON_SOCK} < 100 )) || die "VM_DIR is too long: the monitor socket path would exceed the unix socket limit"

SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=20 -o ServerAliveCountMax=6)

# ---- auto detection ------------------------------------------------------------
# CPUs the container may really use: cpuset (nproc) limited by the cgroup CPU quota.
detect_cpus() {
  local n q="" p=""
  n=$(nproc 2>/dev/null || echo 1)
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=1
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then                      # cgroup v2: "max 100000" or "150000 100000"
    read -r q p < /sys/fs/cgroup/cpu.max || true
  elif [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us && -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then   # cgroup v1
    read -r q < /sys/fs/cgroup/cpu/cpu.cfs_quota_us || true
    read -r p < /sys/fs/cgroup/cpu/cpu.cfs_period_us || true
  fi
  if [[ "$q" =~ ^[0-9]+$ && "$p" =~ ^[1-9][0-9]*$ ]]; then
    q=$(( (q + p - 1) / p ))
    if (( q >= 1 && q < n )); then n=$q; fi
  fi
  echo "$n"
}

# RAM the container may really use, in MiB: the smaller one of the cgroup limit and MemTotal.
detect_mem_limit_mib() {
  local total_kb lim f v
  total_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
  [[ "$total_kb" =~ ^[0-9]+$ ]] || die "cannot read MemTotal from /proc/meminfo"
  lim=$(( total_kb / 1024 ))
  for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
    if [[ -r "$f" ]]; then
      v=$(cat "$f" 2>/dev/null || true)
      # "max" (v2) or a huge number (v1 = no limit) is ignored; 15 digits keep the arithmetic safe
      if [[ "$v" =~ ^[0-9]{1,15}$ ]] && (( v / 1048576 < lim )); then lim=$(( v / 1048576 )); fi
      break
    fi
  done
  echo "$lim"
}

# free space in MiB of the filesystem that holds $1
free_mib() {
  df -Pk -- "$1" 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ {print int($4 / 1024)}' || true
}

# virtual size in MiB of the VM disk (the disk must not be in use)
disk_virtual_mib() {
  qemu-img info --output=json "$DISK_IMAGE" 2>/dev/null \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["virtual-size"] // 1048576)' 2>/dev/null || true
}

if [[ -r /dev/kvm && -w /dev/kvm ]]; then KVM=1; else KVM=0; fi

if [[ "$CPUS" == auto ]]; then CPUS=$(detect_cpus); fi

MEM_LIMIT_MIB=$(detect_mem_limit_mib)
if (( KVM == 1 )); then
  TCG_TB_SIZE_MB=0                                  # no code cache with KVM
elif [[ "$TCG_TB_SIZE_MB" == auto ]]; then
  TCG_TB_SIZE_MB=$(( MEM_LIMIT_MIB * 12 / 100 ))
  if (( TCG_TB_SIZE_MB < 48 )); then TCG_TB_SIZE_MB=48; fi
  if (( TCG_TB_SIZE_MB > 256 )); then TCG_TB_SIZE_MB=256; fi
fi
if [[ "$HOST_RESERVE_MIB" == auto ]]; then
  HOST_RESERVE_MIB=$(( MEM_LIMIT_MIB * 20 / 100 ))
  if (( HOST_RESERVE_MIB < 160 )); then HOST_RESERVE_MIB=160; fi
  if (( HOST_RESERVE_MIB > 1024 )); then HOST_RESERVE_MIB=1024; fi
fi
if [[ "$MEMORY_MIB" == auto ]]; then
  MEMORY_MIB=$(( MEM_LIMIT_MIB - TCG_TB_SIZE_MB - HOST_RESERVE_MIB ))
  MEMORY_MIB=$(( MEMORY_MIB - MEMORY_MIB % 4 ))
  (( MEMORY_MIB >= 128 )) || die "container RAM limit is ${MEM_LIMIT_MIB} MiB: after the TCG cache (${TCG_TB_SIZE_MB}) and the host reserve (${HOST_RESERVE_MIB}) less than 128 MiB is left for the guest; raise the limit"
fi
NEED_MIB=$(( MEMORY_MIB + TCG_TB_SIZE_MB + HOST_RESERVE_MIB ))
if (( NEED_MIB > MEM_LIMIT_MIB )); then
  die "guest ${MEMORY_MIB} + TCG cache ${TCG_TB_SIZE_MB} + host reserve ${HOST_RESERVE_MIB} = ${NEED_MIB} MiB does not fit into the container limit of ${MEM_LIMIT_MIB} MiB; lower MEMORY_MIB / TCG_TB_SIZE_MB or raise the limit"
fi
log "Resources: CPUs=$CPUS; container RAM ${MEM_LIMIT_MIB} MiB = guest ${MEMORY_MIB} + TCG cache ${TCG_TB_SIZE_MB} + host reserve ${HOST_RESERVE_MIB} = ${NEED_MIB} MiB"

# ---- bg helpers ----------------------------------------------------------------
# sleep that a trapped signal (docker stop) can interrupt immediately
isleep() { sleep "$1" & wait $! || true; }

# kill_tree PID -> kill a background job AND everything it spawned (sleep, $(...) subshells,
# python monitor clients, tail|sed pipelines). Children are listed first so nothing is missed
# when the parent dies and its children get re-parented.
kill_tree() {
  local pid=$1 kids c
  kids=$(pgrep -P "$pid" 2>/dev/null || true)
  kill "$pid" 2>/dev/null || true
  for c in $kids; do kill_tree "$c"; done
}

stop_bg() {
  local p
  for p in "$SNAP_PID" "$WEB_PID" "$TUN_PID"; do
    if [[ -n "$p" ]]; then kill_tree "$p"; fi
  done
  SNAP_PID=""; WEB_PID=""; TUN_PID=""
}

# stop_qemu -> SIGTERM, then SIGKILL if QEMU is stuck (e.g. in the middle of a savevm)
stop_qemu() {
  local i
  kill "$QEMU_PID" 2>/dev/null || true
  for ((i = 0; i < 50; i++)); do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$QEMU_PID" 2>/dev/null; then
    log "QEMU did not stop within 10s -> SIGKILL"
    kill -9 "$QEMU_PID" 2>/dev/null || true
  fi
  wait "$QEMU_PID" 2>/dev/null || true
}

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

# snapshot_tags -> one snapshot tag per line (disk must not be in use)
snapshot_tags() {
  qemu-img snapshot -l "$DISK_IMAGE" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $2}' || true
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
  if [[ -s "$SNAP_FILE" ]]; then old=$(head -n1 "$SNAP_FILE"); fi
  if [[ "$tag" == "$old" ]]; then tag="${tag}b"; fi   # two snapshots within the same second
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

# find_resume_candidate -> sets RESUME_TAG when a usable snapshot exists
find_resume_candidate() {
  local cand snaps
  RESUME_TAG=""
  # No ready mark = the disk/snapshot comes from an older script version (or the ssh key was
  # regenerated): the guest does not know our key yet, so only a cold boot (new seed) can fix that.
  if [[ "$RESUME" != 1 || ! -s "$SNAP_FILE" || ! -s "$DISK_IMAGE" || ! -s "$SEED_IMAGE" || ! -e "$READY_MARK" ]]; then
    return 0
  fi
  cand=$(sed -n 1p "$SNAP_FILE")
  if [[ -z "$cand" ]]; then return 0; fi
  snaps=$(snapshot_tags)
  if grep -qxF -- "$cand" <<<"$snaps"; then RESUME_TAG=$cand; fi
  return 0
}
# <<< snapshot helpers <<<

cleanup() {
  stop_bg
  if [[ -n "$TAIL_PID" ]]; then kill_tree "$TAIL_PID"; TAIL_PID=""; fi
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    if (( SNAP_READY == 1 && SNAPSHOT_INTERVAL_MIN > 0 && SNAPSHOT_STOP_TIMEOUT_SEC > 0 )); then
      log "Saving a final VM snapshot (max ${SNAPSHOT_STOP_TIMEOUT_SEC}s)..."
      take_snapshot "$SNAPSHOT_STOP_TIMEOUT_SEC" keep || log "final snapshot skipped"
    fi
    log "Stopping VM..."
    stop_qemu
  fi
  # Only touch shared state (monitor socket) if this process owns the lock;
  # an instance that died on "another VM is already using ..." must not break the running one.
  if (( LOCK_HELD == 1 )); then
    rm -f "$MON_SOCK" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---- single-instance lock (taken before touching any shared state) ------------
# flock is released by the kernel when the last process holding the descriptor exits, so there
# are no stale locks and no PID-reuse false positives after a container restart. The descriptor
# is inherited by QEMU: if this script is killed but QEMU survives, the VM dir stays locked.
exec 9>"$LOCK_FILE" || die "cannot open lock file $LOCK_FILE"
flock -n 9 || die "another VM is already using $VM_DIR"
LOCK_HELD=1

# ---- downloads ---------------------------------------------------------------
# Only fetch publisher-controlled HTTPS URLs. Downloads are atomic.
require_https_url() {
  [[ "$1" == https://* ]] || die "URL must use HTTPS: $1"
}
# fetch URL DEST [nosums]: download atomically; verified against the SHA256SUMS of its directory
# unless "nosums" is given
fetch() {
  require_https_url "$1"
  local url=$1 dest=$2 mode=${3:-} name sums
  name=${url##*/}
  log "Downloading $name..."
  rm -f "$dest.part"
  wget -q --show-progress --progress=dot:giga --tries=3 --timeout=30 -O "$dest.part" "$url" || { rm -f "$dest.part"; return 1; }
  if [[ "$mode" != nosums ]]; then
    sums=$(wget -qO- --tries=3 --timeout=30 "${url%/*}/SHA256SUMS" 2>/dev/null | awk -v n="$name" '{gsub(/^\*/, "", $NF); if ($NF == n) {print $1; exit}}' || true)
    [[ "$sums" =~ ^[0-9a-fA-F]{64}$ ]] || { rm -f "$dest.part"; log "no valid SHA256 entry for $name"; return 1; }
    if [[ "$(sha256sum "$dest.part" | awk '{print $1}')" != "$sums" ]]; then
      rm -f "$dest.part"; log "checksum mismatch for $name"; return 1
    fi
    log "$name checksum OK"
  fi
  mv "$dest.part" "$dest"
}

# ensure_tool NAME GITHUB_URL VARIABLE [nosums]: use the tool from PATH, else the copy in $BIN_DIR,
# else download it from its official GitHub release.
ensure_tool() {
  local name=$1 url=$2 var=$3 mode=${4:-} path
  path=$(command -v "$name" 2>/dev/null || true)
  if [[ -z "$path" && -x "$BIN_DIR/$name" ]]; then path="$BIN_DIR/$name"; fi
  if [[ -z "$path" ]]; then
    mkdir -p "$BIN_DIR"
    log "$name not found in PATH -> downloading it into $BIN_DIR"
    fetch "$url" "$BIN_DIR/$name" "$mode" || die "could not download $name; install it into the image instead"
    chmod 755 "$BIN_DIR/$name"
    path="$BIN_DIR/$name"
  fi
  "$path" --version >/dev/null 2>&1 || die "$name at $path does not run (wrong architecture or broken download?)"
  printf -v "$var" '%s' "$path"
}

case "$(uname -m)" in
  x86_64)        TTYD_ARCH=x86_64;  CF_ARCH=amd64; HOST_X86=1 ;;
  aarch64|arm64) TTYD_ARCH=aarch64; CF_ARCH=arm64; HOST_X86=0 ;;
  *) TTYD_ARCH="";                  CF_ARCH="";    HOST_X86=0 ;;
esac
if [[ -z "$TTYD_ARCH" ]]; then
  # unknown CPU: only works when both tools are already installed
  TTYD_URL="https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.unsupported"
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-unsupported"
else
  TTYD_URL="https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.$TTYD_ARCH"
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH"
fi
ensure_tool ttyd "$TTYD_URL" TTYD_BIN
ensure_tool cloudflared "$CF_URL" CF_BIN nosums

# ---- ssh key pair (web terminal -> guest) ---------------------------------------
if [[ ! -s "$SSH_KEY" || ! -s "$SSH_KEY.pub" ]]; then
  rm -f "$SSH_KEY" "$SSH_KEY.pub" "$READY_MARK"     # no ready mark -> an existing disk is cold-booted with the new key
  ssh-keygen -q -t ed25519 -N '' -C "qemu-web-shell" -f "$SSH_KEY"
  log "Generated the web terminal ssh key pair"
fi
chmod 600 "$SSH_KEY"

# ---- web terminal (ttyd) + tunnel (cloudflared) ----------------------------------
# The command ttyd runs for every browser tab: wait until the VM answers on ssh, then open a shell.
write_web_shell() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'SSH_PORT=%q\nSSH_KEY=%q\nGUEST_USER=%q\nSERIAL_LOG=%q\nROOT_SHELL=%q\n' \
      "$SSH_PORT" "$SSH_KEY" "$GUEST_USER" "$SERIAL_LOG" "$GUEST_ROOT_SHELL"
    cat <<'WRAP'
export LANG=C.UTF-8 LC_ALL=C.UTF-8      # forwarded to the guest by ssh; C.UTF-8 exists in every Ubuntu
SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=20 -o ServerAliveCountMax=6)
probe() {
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=120 "$GUEST_USER@127.0.0.1" true </dev/null >/dev/null 2>&1
}
if ! probe; then
  printf 'The Ubuntu VM is still starting (software emulation can take 10-40 minutes).\r\n'
  printf 'This page connects by itself as soon as it is ready. Ctrl-C closes it.\r\n\r\n'
  t0=$SECONDS
  until probe; do
    last=$(tail -n 1 "$SERIAL_LOG" 2>/dev/null | sed -r 's/\x1B\[[0-9;?]*[A-Za-z]//g' | tr -d '\r' | cut -c1-72)
    printf '\r\033[K[%ds] %s' "$(( SECONDS - t0 ))" "$last"
    sleep 5
  done
  printf '\r\033[K\r\nVM is ready.\r\n'
fi
if [[ "$ROOT_SHELL" == 1 ]]; then
  exec ssh -t "${SSH_OPTS[@]}" "$GUEST_USER@127.0.0.1" 'sudo -i'
fi
exec ssh -t "${SSH_OPTS[@]}" "$GUEST_USER@127.0.0.1"
WRAP
  } > "$WEB_SHELL.part"
  chmod 700 "$WEB_SHELL.part"
  mv -f "$WEB_SHELL.part" "$WEB_SHELL"
}

# bg_alive -> the main script is still running (background loops stop themselves otherwise)
bg_alive() { kill -0 "$MAIN_PID" 2>/dev/null; }

print_link_banner() {
  printf '\n==================== WEB TERMINAL LINK ====================\n'
  printf '%s\n' "$1"
  printf 'user: %s   password: the value of PAS\n' "$WEB_USER"
  printf '===========================================================\n\n'
}

# ttyd_loop: keep ttyd running (restart on crash)
ttyd_loop() {
  local pid help args
  args=(-p "$WEB_PORT" -i "$WEB_BIND" -c "${WEB_USER}:${WEB_PASS}" -m "$WEB_MAX_CLIENTS" -t "titleFixed=Ubuntu VM")
  # ttyd >= 1.7 is read-only unless -W is given; 1.6 does not know -W (it is writable by default)
  help=$("$TTYD_BIN" --help 2>&1 || true)
  if [[ "$help" == *--writable* ]]; then args+=(-W); fi
  while bg_alive; do
    "$TTYD_BIN" "${args[@]}" bash "$WEB_SHELL" 9>&- &
    pid=$!
    wait "$pid" || true
    bg_alive || break
    log "ttyd exited -> restarting in 3s"
    sleep 3
  done
}

# tunnel_loop: keep a cloudflared quick tunnel running and print its link whenever it changes
tunnel_loop() {
  local pid url last="" delay=5 started
  while bg_alive; do
    : > "$CF_LOG"
    started=$SECONDS
    "$CF_BIN" tunnel --no-autoupdate --protocol "$CF_PROTOCOL" --url "http://$WEB_HOST:$WEB_PORT" >> "$CF_LOG" 2>&1 9>&- &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && bg_alive; do
      url=$(grep -aoE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | grep -av '^https://api\.' | tail -n 1 || true)
      if [[ -n "$url" && "$url" != "$last" ]]; then
        last=$url
        printf '%s\n' "$url" > "$TUNNEL_URL_FILE.part"
        mv -f "$TUNNEL_URL_FILE.part" "$TUNNEL_URL_FILE"
        print_link_banner "$url"
      fi
      sleep 2
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    bg_alive || break
    rm -f "$TUNNEL_URL_FILE"; last=""
    if (( SECONDS - started > 60 )); then delay=5; elif (( delay < 60 )); then delay=$(( delay * 2 )); fi
    log "cloudflared exited -> restarting in ${delay}s (a new tunnel gets a NEW link). Last output:"
    tail -n 5 "$CF_LOG" 2>/dev/null | sed 's/^/[cloudflared] /' || true
    sleep "$delay"
  done
}

rm -f "$TUNNEL_URL_FILE" "$TUNNEL_URL_FILE.part" "$VM_DIR/sshx-url" "$VM_DIR/sshx-url.part"
write_web_shell

if (exec 3<>"/dev/tcp/$WEB_HOST/$WEB_PORT") 2>/dev/null; then
  die "port $WEB_PORT is already in use by another program; set PORT to a free port"
fi
ttyd_loop &
WEB_PID=$!
web_ready=0
for ((i = 0; i < 100; i++)); do
  if (exec 3<>"/dev/tcp/$WEB_HOST/$WEB_PORT") 2>/dev/null; then web_ready=1; break; fi
  sleep 0.1
done
(( web_ready == 1 )) || die "ttyd did not start listening on port $WEB_PORT (port already in use?)"
log "Web terminal (ttyd) listening on $WEB_BIND:$WEB_PORT"

tunnel_loop &
TUN_PID=$!
for ((i = 0; i < CF_WAIT_SEC; i++)); do
  if [[ -s "$TUNNEL_URL_FILE" ]]; then break; fi
  sleep 1
done
if [[ ! -s "$TUNNEL_URL_FILE" ]]; then
  log "WARNING: no tunnel link after ${CF_WAIT_SEC}s; cloudflared keeps retrying, the link will be printed as soon as it exists. Last output:"
  tail -n 5 "$CF_LOG" 2>/dev/null | sed 's/^/[cloudflared] /' || true
fi

# ---- resume candidate ------------------------------------------------------------
if (( SNAPSHOT_INTERVAL_MIN == 0 )) && [[ "$RESUME" == 1 ]]; then
  log "SNAPSHOT_INTERVAL_MIN=0 -> resume disabled; any old snapshot will be discarded"
  RESUME=0
fi
find_resume_candidate

# ---- VM files --------------------------------------------------------------------
if [[ "$DIRECT_KERNEL" == 1 && -s "$BASE_IMAGE" && ! ( -s "$KERNEL" && -s "$INITRD" ) ]]; then
  # kernel/initrd must come from the same build as base.img -> all three have to be refreshed together.
  # That needs a new overlay disk, so never do it silently when a disk with data already exists.
  if [[ -e "$DISK_IMAGE" ]]; then
    die "kernel/initrd are missing but $DISK_IMAGE already exists; refusing to delete your VM disk. Either set DIRECT_KERNEL=0, or back up and remove $BASE_IMAGE and $DISK_IMAGE yourself to start fresh"
  fi
  log "Kernel/initrd missing for existing image -> re-downloading matching set"
  rm -f "$BASE_IMAGE"
fi
if [[ ! -s "$BASE_IMAGE" ]]; then
  if [[ -e "$DISK_IMAGE" ]]; then
    # the overlay is useless without its backing file, but never delete user data silently
    log "WARNING: base image is missing but $DISK_IMAGE exists -> moving it to $DISK_IMAGE.orphaned"
    mv -f "$DISK_IMAGE" "$DISK_IMAGE.orphaned"
    RESUME_TAG=""
    rm -f "$SNAP_FILE" "$READY_MARK"
  fi
  fetch "$IMAGE_URL" "$BASE_IMAGE" || die "image download failed"
  rm -f "$KERNEL" "$INITRD"     # new base image -> kernel/initrd must be re-fetched as a matching set
fi
if [[ "$DIRECT_KERNEL" == 1 && ! ( -s "$KERNEL" && -s "$INITRD" ) ]]; then
  if ! { fetch "$KERNEL_URL" "$KERNEL" && fetch "$INITRD_URL" "$INITRD"; }; then
    die "kernel/initrd download failed; refusing to boot an unverified build"
  fi
fi
if [[ ! -s "$DISK_IMAGE" ]]; then
  if [[ "$DISK_SIZE" == auto ]]; then
    # Everything that is free now (the base image is already downloaded), minus room for the live
    # snapshots (the old and the new one exist at the same time = 2x guest RAM) and a safety margin.
    avail=$(free_mib "$VM_DIR")
    [[ "$avail" =~ ^[0-9]+$ ]] || die "cannot determine the free space of $VM_DIR; set DISK_SIZE manually"
    snap_mib=0
    if (( SNAPSHOT_INTERVAL_MIN > 0 )); then snap_mib=$(( 2 * MEMORY_MIB )); fi
    margin=$(( avail / 20 )); if (( margin < 256 )); then margin=256; fi
    disk_mib=$(( avail - snap_mib - margin ))
    (( disk_mib >= 4096 )) || die "only ${avail} MiB free in $VM_DIR; at least $(( 4096 + snap_mib + margin )) MiB are needed. Free some space or set DISK_SIZE"
    DISK_SIZE="${disk_mib}M"
    log "Disk: ${avail} MiB free -> VM disk ${disk_mib} MiB (reserved: snapshots ${snap_mib} MiB + margin ${margin} MiB)"
  fi
  log "Creating VM disk ($DISK_SIZE)..."
  rm -f "$DISK_IMAGE.part"
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK_IMAGE.part" "$DISK_SIZE"
  mv -f "$DISK_IMAGE.part" "$DISK_IMAGE"
else
  log "Using the existing VM disk (the size of an existing disk is not changed)"
fi
DISK_MIB=$(disk_virtual_mib)
[[ "$DISK_MIB" =~ ^[0-9]+$ ]] || DISK_MIB=20480

# ---- cloud-init (tuned for small guests) -------------------------------------
# - no packages/package_update: apt update -> appstreamcli/apt-check -> OOM.
#   curl/openssh-server already ship in the Ubuntu server cloud image.
# - ssh_authorized_keys: lets the web terminal log in as "ubuntu" (key only, password login stays off).
# - bootcmd (every boot): swap file, longer systemd timeouts + nofail for /boot,/boot/efi,
#   removal of the old sshx service of previous script versions (and, when FULL_VM=0, heavy services masked).
# - timefix.service: after a snapshot resume the guest clock is stale; re-syncing it keeps apt/TLS working.
# Only used on a cold boot; a resumed VM keeps the seed it was started with.
write_seed() {
local swap=$GUEST_SWAP_MB pubkey
pubkey=$(head -n1 "$SSH_KEY.pub")
if [[ "$swap" == auto ]]; then
  swap=$(( DISK_MIB / 8 )); if (( swap > 1024 )); then swap=1024; fi
fi
GUEST_SWAP_USED=$swap
cat > "$VM_DIR/user-data" <<CLOUD
#cloud-config
hostname: ubuntu-vm
preserve_hostname: false
package_update: false
package_upgrade: false
package_reboot_if_required: false
ssh_authorized_keys:
  - "${pubkey}"
growpart:
  mode: auto
resize_rootfs: true
bootcmd:
  - [sh, -c, 'command -v growpart >/dev/null 2>&1 && growpart /dev/vda 1 >/dev/null 2>&1 || true; command -v resize2fs >/dev/null 2>&1 && resize2fs /dev/vda1 >/dev/null 2>&1 || true; S=${swap}; if [ "\$S" -gt 0 ] && ! swapon --show=NAME --noheadings | grep -q /swapfile; then [ -f /swapfile ] || { fallocate -l \${S}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=\$S; chmod 600 /swapfile; mkswap /swapfile; }; swapon /swapfile; fi; sysctl -w vm.swappiness=60 >/dev/null; true']
  - [sh, -c, 'for u in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service motd-news.timer motd-news.service man-db.timer fwupd-refresh.timer packagekit.service ModemManager.service udisks2.service multipathd.service multipathd.socket fwupd.service fstrim.timer e2scrub_all.timer e2scrub_reap.service ua-timer.timer ubuntu-advantage.service pollinate.service lxd-installer.socket apport.service; do systemctl --no-block stop "\$u" 2>/dev/null; systemctl mask "\$u" 2>/dev/null; done; true']
  - [sh, -c, 'rm -f /etc/apt/apt.conf.d/50appstream /etc/apt/apt.conf.d/99update-notifier; chmod -x /etc/update-motd.d/50-motd-news /etc/update-motd.d/90-updates-available /etc/update-motd.d/91-release-upgrade 2>/dev/null; true']
  - [sh, -c, 'mkdir -p /etc/systemd/system.conf.d; printf "[Manager]\nDefaultTimeoutStartSec=${GUEST_UNIT_TIMEOUT_SEC}s\nDefaultDeviceTimeoutSec=${GUEST_UNIT_TIMEOUT_SEC}s\n" > /etc/systemd/system.conf.d/90-slow-tcg.conf; sed -i -E "/LABEL=(BOOT|UEFI)[[:space:]]/{/nofail/!s/^([^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)([^[:space:]]+)/\1\2,nofail,x-systemd.device-timeout=${GUEST_UNIT_TIMEOUT_SEC}s/}" /etc/fstab; true']
  - [sh, -c, 'if [ -e /etc/systemd/system/sshx.service ]; then systemctl disable --now sshx.service >/dev/null 2>&1; rm -f /etc/systemd/system/sshx.service /usr/local/bin/run-sshx.sh; fi; true']
write_files:
  - path: /etc/systemd/system/timefix.service
    content: |
      [Unit]
      Description=Re-sync guest clock (needed after a VM snapshot resume)
      [Service]
      ExecStart=/bin/sh -c 'while sleep 60; do systemctl restart systemd-timesyncd; done'
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --no-block, --now, timefix.service]
CLOUD
# new instance-id every cold start => cloud-init always re-applies the config
printf 'instance-id: vm-%s-%s\nlocal-hostname: ubuntu-vm\n' "$(date +%s)" "$$" > "$VM_DIR/meta-data"
if [[ "$FULL_VM" == 1 ]]; then
  # keep every stock service/timer/MOTD hook: drop the "mask heavy services" and apt/motd tweak lines
  sed -i -e '/systemctl mask/d' -e '/50appstream/d' "$VM_DIR/user-data"
fi
cloud-localds "$SEED_IMAGE" "$VM_DIR/user-data" "$VM_DIR/meta-data"
}

# ---- accelerator -------------------------------------------------------------
if (( KVM == 1 )); then
  log "KVM detected -> hardware acceleration"
  ACCEL=(-accel kvm -cpu host)
else
  # Multi-threaded TCG is only safe on an x86 host (same memory ordering as the x86 guest) and only
  # helps with several vCPUs; otherwise single-thread TCG is correct and has less overhead.
  if (( CPUS > 1 && HOST_X86 == 1 )); then TCG_THREAD=multi; else TCG_THREAD=single; fi
  log "KVM not available -> TCG software emulation (slow, can take 10-40 min); cpu=$CPU_MODEL thread=$TCG_THREAD tb=${TCG_TB_SIZE_MB}M"
  ACCEL=(-accel "tcg,thread=${TCG_THREAD},tb-size=${TCG_TB_SIZE_MB}" -cpu "$CPU_MODEL")
fi

# ---- floppy ------------------------------------------------------------------
# The "pc" machine always creates an ISA floppy controller. Without a disk inserted the guest
# keeps polling /dev/fd0 and logs "I/O error, dev fd0, sector 0". Declaring the drive type
# "none" removes the drive, so the guest never sees fd0.
# Changes the machine definition: a snapshot made without this option may fail to load; the
# resume code below then falls back to a cold boot automatically (disk data is kept).
FLOPPY=()
if [[ "$DISABLE_FLOPPY" == 1 ]]; then
  FLOPPY=(-global isa-fdc.fdtypeA=none -global isa-fdc.fdtypeB=none)
fi

# ---- boot options (direct kernel boot only) ----------------------------------
BOOT=()
if [[ "$DIRECT_KERNEL" == 1 ]]; then
  T=$GUEST_UNIT_TIMEOUT_SEC
  CMDLINE="root=LABEL=cloudimg-rootfs ro console=ttyS0,115200n8 ds=nocloud"
  CMDLINE+=" systemd.default_device_timeout_sec=$T systemd.default_timeout_start_sec=$T"
  # Second layer: even if a floppy device shows up, never auto-load the floppy driver.
  if [[ "$DISABLE_FLOPPY" == 1 ]]; then CMDLINE+=" modprobe.blacklist=floppy"; fi
  if [[ "$FULL_VM" == 1 ]]; then
    # Normal Ubuntu behaviour: all services enabled, AppArmor on, normal boot messages.
    CMDLINE+=" loglevel=4 nokaslr"
  else
    # loglevel=4 keeps the kernel "Out of memory" messages visible (they are level 3)
    CMDLINE+=" quiet loglevel=4 systemd.show_status=0 mitigations=off nokaslr audit=0"
    for u in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service \
             unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer \
             motd-news.timer man-db.timer fwupd-refresh.timer ModemManager.service \
             multipathd.service multipathd.socket udisks2.service packagekit.service \
             fstrim.timer e2scrub_all.timer e2scrub_reap.service ua-timer.timer \
             ubuntu-advantage.service pollinate.service lxd-installer.socket apport.service; do
      CMDLINE+=" systemd.mask=$u"
    done
    if [[ "$GUEST_APPARMOR" == 0 ]]; then CMDLINE+=" apparmor=0"; fi
  fi
  BOOT=(-kernel "$KERNEL" -initrd "$INITRD" -append "$CMDLINE")
  log "Direct kernel boot: $CMDLINE"
else
  log "Disk (GRUB) boot: guest timeouts apply from the 2nd boot on"
fi

# launch_qemu [SNAPSHOT_TAG]  -> starts QEMU in the background and sets QEMU_PID.
# The machine definition must stay identical between runs, otherwise a snapshot cannot be loaded.
# MALLOC_ARENA_MAX=1 keeps glibc from creating per-thread arenas (saves tens of MiB with TCG threads).
# The only network exposure is the guest's sshd on 127.0.0.1:$SSH_PORT (loopback, key login only).
launch_qemu() {
  local extra=()
  if [[ -n "${1:-}" ]]; then extra=(-loadvm "$1"); fi
  rm -f "$MON_SOCK"
  MALLOC_ARENA_MAX=1 qemu-system-x86_64 "${ACCEL[@]}" \
    -machine "$MACHINE" -m "${MEMORY_MIB}M" -smp "$CPUS" \
    "${FLOPPY[@]}" \
    "${BOOT[@]}" "${extra[@]}" \
    -drive "file=$DISK_IMAGE,if=virtio,format=qcow2,cache=${DISK_CACHE},aio=threads" \
    -drive "file=$SEED_IMAGE,if=virtio,format=raw,readonly=on" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -device virtio-rng-pci \
    -vga none -display none -no-reboot \
    -monitor "unix:$MON_SOCK,server,nowait" \
    -chardev "file,id=ser0,path=$SERIAL_LOG,append=on" -serial chardev:ser0 &
  QEMU_PID=$!
}

# ssh_probe -> 0 when the guest accepts our key (runs in the background so a trapped signal is not delayed)
ssh_probe() {
  local p
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=120 "$GUEST_USER@127.0.0.1" true \
    </dev/null >/dev/null 2>"$SSH_PROBE_LOG" 9>&- &
  p=$!
  wait "$p"
}

# ---- resume or cold boot -----------------------------------------------------
if (exec 3<>"/dev/tcp/127.0.0.1/$SSH_PORT") 2>/dev/null; then
  die "SSH_PORT $SSH_PORT is already in use by another program; set SSH_PORT to a free port"
fi
if [[ -n "$RESUME_TAG" ]]; then
  log "Found VM snapshot $RESUME_TAG -> resuming the previous VM..."
  prune_snapshots "$RESUME_TAG"
  : > "$SERIAL_LOG"
  launch_qemu "$RESUME_TAG"
  if wait_resumed; then
    RESUMED=1
    log "VM resumed from snapshot"
  else
    log "WARNING: resume failed (e.g. CPU/RAM/machine settings changed since the snapshot) -> falling back to a cold boot (disk data is kept)"
    stop_qemu
    QEMU_PID=""
  fi
fi

if (( RESUMED == 0 )); then
  prune_snapshots ""
  rm -f "$SNAP_FILE" "$SNAP_FILE.part"
  write_seed
  : > "$SERIAL_LOG"
  log "Booting Ubuntu (guest RAM=${MEMORY_MIB}M, guest swap=${GUEST_SWAP_USED}M, disk=${DISK_MIB}M, CPUs=$CPUS)..."
  launch_qemu ""
  if [[ "$SHOW_BOOT_LOG" == "1" ]]; then
    # own subshell, so that cleanup can kill both tail and sed
    ( tail -n +1 -F "$SERIAL_LOG" 2>/dev/null \
        | sed -u -r 's/\x1B\[[0-9;?]*[A-Za-z]//g; s/\r//g; s/^/[vm] /' ) 9>&- &
    TAIL_PID=$!
  fi
fi

# ---- wait until the guest accepts the web terminal's ssh login -------------------
START=$(date +%s); LAST=0; OOM_WARNED=0
until ssh_probe; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    RC=0; wait "$QEMU_PID" 2>/dev/null || RC=$?
    QEMU_PID=""
    log "QEMU exited unexpectedly (exit code $RC). Last console lines:"
    tail -n 50 "$SERIAL_LOG" || true
    exit 1
  fi
  if (( OOM_WARNED == 0 )) && grep -aq 'Out of memory: Killed process' "$SERIAL_LOG" 2>/dev/null; then
    log "WARNING: guest OOM killer fired (see [vm] lines)"; OOM_WARNED=1
  fi
  ELAPSED=$(( ($(date +%s) - START) / 60 ))
  if (( ELAPSED >= BOOT_TIMEOUT_MIN )); then
    log "The VM did not accept ssh logins after ${BOOT_TIMEOUT_MIN} min. Last ssh error: $(tail -n 1 "$SSH_PROBE_LOG" 2>/dev/null || true)"
    log "Last console lines:"
    tail -n 50 "$SERIAL_LOG" || true
    exit 1
  fi
  if (( ELAPSED > LAST )); then LAST=$ELAPSED; log "still booting... ${ELAPSED} min"; fi
  isleep 5
done
: > "$READY_MARK"

if [[ -n "$TAIL_PID" ]]; then kill_tree "$TAIL_PID"; TAIL_PID=""; fi
log "VM is up and reachable."
if [[ -s "$TUNNEL_URL_FILE" ]]; then
  print_link_banner "$(head -n1 "$TUNNEL_URL_FILE")"
else
  log "The tunnel link is not available yet; it will be printed here as soon as cloudflared has it."
fi

# ---- background job: periodic snapshots --------------------------------------
# nap SECONDS -> sleep in short steps; returns 1 as soon as QEMU or the main script is gone, so
# this background job can never outlive them (an orphan would keep the VM-dir lock forever)
nap() {
  local left=$1 step
  while (( left > 0 )); do
    kill -0 "$QEMU_PID" 2>/dev/null && kill -0 "$MAIN_PID" 2>/dev/null || return 1
    step=5; if (( left < step )); then step=$left; fi
    sleep "$step"
    left=$(( left - step ))
  done
  kill -0 "$QEMU_PID" 2>/dev/null && kill -0 "$MAIN_PID" 2>/dev/null || return 1
}
snapshot_loop() {
  nap "$SNAPSHOT_FIRST_DELAY_SEC" || return 0
  while true; do
    take_snapshot "$SNAPSHOT_TIMEOUT_SEC" || log "WARNING: periodic snapshot failed"
    nap $(( SNAPSHOT_INTERVAL_MIN * 60 )) || return 0
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

log "VM is running. Stop with: docker stop -t 60 <container>"
RC=0; wait "$QEMU_PID" || RC=$?
QEMU_PID=""
stop_bg
if (( RC == 0 )); then
  # The guest shut down / rebooted by itself: its disk is the newest state. Restoring an
  # older snapshot on the next start would roll that work back, so boot from the disk instead.
  log "QEMU exited cleanly (guest shutdown/reboot) -> discarding the VM snapshot; next start boots from the disk"
  prune_snapshots ""
  rm -f "$SNAP_FILE" "$SNAP_FILE.part"
fi
log "QEMU exited (exit code $RC)"
exit "$RC"
