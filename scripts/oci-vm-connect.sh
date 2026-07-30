#!/usr/bin/env bash
#
# oci-vm-connect.sh — find your OCI instances and set up SSH from Termux.
#
# Supports multiple OCI profiles for managing different instances.
#
#   bash oci-vm-connect.sh --list                    # list all running instances
#   bash oci-vm-connect.sh --list --profile VMX86   # list instances for profile
#   bash oci-vm-connect.sh --setup-key               # create/show an SSH key
#   bash oci-vm-connect.sh --connect <ip>            # ssh in
#   bash oci-vm-connect.sh --connect roc-vm-x86      # ssh using SSH config alias
#   bash oci-vm-connect.sh --trust-host <ip>         # let rootd box trust the VM
#   bash oci-vm-connect.sh --instances               # list instances with details
#
set -euo pipefail

ACTION=""
TARGET=""
SSH_USER="ubuntu"
BOX="docker"
KEY_TYPE="ed25519"
KEY_PATH="$HOME/.ssh/id_ed25519"
COMPARTMENT=""
PROFILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --list)        ACTION="list" ;;
        --instances)   ACTION="instances" ;;
        --setup-key)   ACTION="setupkey" ;;
        --connect)
            ACTION="connect"
            if [ $# -lt 2 ] || case "${2:-}" in -*) true ;; *) false ;; esac; then
                echo "error: --connect needs an address, e.g. --connect 1.2.3.4" >&2
                exit 2
            fi
            shift; TARGET="$1" ;;
        --connect=*)   ACTION="connect"; TARGET="${1#*=}" ;;
        --trust-host)
            ACTION="trusthost"
            if [ $# -lt 2 ] || case "${2:-}" in -*) true ;; *) false ;; esac; then
                echo "error: --trust-host needs an address" >&2; exit 2
            fi
            shift; TARGET="$1" ;;
        --trust-host=*) ACTION="trusthost"; TARGET="${1#*=}" ;;
        --box)         shift; BOX="${1:-docker}" ;;
        --box=*)       BOX="${1#*=}" ;;
        --key-type)    shift; KEY_TYPE="${1:-ed25519}" ;;
        --key-type=*)  KEY_TYPE="${1#*=}" ;;
        --user)        shift; SSH_USER="${1:-ubuntu}" ;;
        --user=*)      SSH_USER="${1#*=}" ;;
        --key)         shift; KEY_PATH="${1:-$KEY_PATH}" ;;
        --key=*)       KEY_PATH="${1#*=}" ;;
        --compartment) shift; COMPARTMENT="${1:-}" ;;
        --compartment=*) COMPARTMENT="${1#*=}" ;;
        --profile)     shift; PROFILE="${1:-}" ;;
        --profile=*)   PROFILE="${1#*=}" ;;
        -h|--help)     sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# Color output
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=""; Y=""; R=""; C=""; D=""; B=""; N=""
fi
step() { printf '%s=>%s %s\n' "$G" "$N" "$*" >&2; }
info() { printf '%s::%s %s\n' "$C" "$N" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

[ -n "$ACTION" ] || { sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# Build OCI command with optional profile
OCI_CMD="oci"
[ -n "$PROFILE" ] && OCI_CMD="$OCI_CMD --profile $PROFILE"

if [ -n "$PROFILE" ]; then
    info "using profile: $PROFILE"
fi

# ---------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------

need_oci() {
    command -v oci >/dev/null 2>&1 \
        || die "oci not found — run: bash termux-oci-cli.sh"
}

tenancy_ocid() {
    python3 - "$HOME/.oci/config" <<'PY' 2>/dev/null || true
import configparser, sys
p = configparser.ConfigParser()
p.read(sys.argv[1])
section = sys.argv[2] if len(sys.argv) > 2 else 'DEFAULT'
if section in p:
    print(p[section].get("tenancy", ""))
elif 'DEFAULT' in p:
    print(p['DEFAULT'].get("tenancy", ""))
else:
    print(p.defaults().get("tenancy", ""))
PY
"${PROFILE:-}"
}

list_profiles() {
    step "available OCI profiles in ~/.oci/config"
    echo ""
    python3 - "$HOME/.oci/config" <<'PY' 2>/dev/null
import configparser, sys
p = configparser.ConfigParser()
p.read(sys.argv[1])
for section in p.sections():
    region = p[section].get("region", "N/A")
    tenancy = p[section].get("tenancy", "N/A")
    print(f"  {G}{section}{N}: region={region}, tenancy={tenancy[:20]}...")
PY
    echo ""
    info "usage: --profile PROFILENAME"
}

list_instances() {
    need_oci
    local comp="${COMPARTMENT:-$(tenancy_ocid)}"
    [ -n "$comp" ] || die "no compartment; pass --compartment ocid1.compartment..."

    step "querying instances (profile: ${PROFILE:-DEFAULT})"
    info "compartment: ${comp:0:40}…"

    local json
    json=$(eval "$OCI_CMD compute instance list --compartment-id \"$comp\" \
             --lifecycle-state RUNNING --all 2>/dev/null) || {
        warn "no instances in that compartment, or access denied"
        printf '\n  List your compartments with:\n'
        printf '    oci iam compartment list --output table\n\n'
        return 1
    }

    printf '\n  %sRunning instances for profile %s%s\n\n' "$B" "${PROFILE:-DEFAULT}" "$N"

    printf '%s' "$json" | python3 -c '
import json, subprocess, sys

try:
    data = json.load(sys.stdin)
except Exception as exc:
    print("    could not parse the instance list: %s" % exc)
    sys.exit(0)

items = data.get("data", [])
if not items:
    print("    none running")
    sys.exit(0)

print("  NAME                    SHAPE                    PUBLIC IP        STATUS")
print("  " + "-"*75)

for inst in items:
    name = inst.get("display-name", "?")
    shape = inst.get("shape", "?")
    state = inst.get("lifecycle-state", "?")
    ocid = inst.get("id", "")
    
    pub_ip = ""
    try:
        out = subprocess.run(
            ["oci", "compute", "instance", "list-vnics", "--instance-id", ocid],
            capture_output=True, text=True, timeout=90,
        )
        vnics = json.loads(out.stdout).get("data", []) if out.stdout.strip() else []
        for v in vnics:
            if v.get("public-ip"):
                pub_ip = v["public-ip"]
    except Exception:
        pass
    
    print(f"  {name:<23} {shape:<25} {pub_ip or \"N/A\":<15} {state}")
'
}

# Detailed instance list
show_instances() {
    need_oci
    local comp="${COMPARTMENT:-$(tenancy_ocid)}"
    [ -n "$comp" ] || die "no compartment"

    step "detailed instance listing (profile: ${PROFILE:-DEFAULT})"

    local json
    json=$(eval "$OCI_CMD compute instance list --compartment-id \"$comp\" \
             --lifecycle-state RUNNING --all 2>/dev/null") || {
        warn "no instances found"
        return 1
    }

    printf '%s' "$json" | python3 -c '
import json, subprocess, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

items = data.get("data", [])
if not items:
    print("  none running")
    sys.exit(0)

for inst in items:
    print("")
    print("  === %s ===" % inst.get("display-name", "?"))
    print("    Shape     : %s" % inst.get("shape", "?"))
    print("    Status    : %s" % inst.get("lifecycle-state", "?"))
    print("    Region    : %s" % inst.get("region", "?"))
    print("    OCID      : %s..." % inst.get("id", "")[:50])
    
    ocid = inst.get("id", "")
    try:
        out = subprocess.run(
            ["oci", "compute", "instance", "list-vnics", "--instance-id", ocid],
            capture_output=True, text=True, timeout=90,
        )
        vnics = json.loads(out.stdout).get("data", []) if out.stdout.strip() else []
        for v in vnics:
            if v.get("public-ip"):
                print("    Public IP : %s" % v["public-ip"])
            if v.get("private-ip"):
                print("    Private IP: %s" % v["private-ip"])
    except Exception:
        pass
'
    echo ""
}

# ---------------------------------------------------------------------
# ssh key
# ---------------------------------------------------------------------

setup_key() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if [ -f "$KEY_PATH" ]; then
        info "using existing key $KEY_PATH"
    else
        step "generating $KEY_PATH"
        ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" -C "termux-$(date +%Y%m%d)" >/dev/null
    fi
    chmod 600 "$KEY_PATH"

    printf '\n  %sYour public key:%s\n\n' "$B" "$N"
    printf '    %s\n\n' "$(cat "$KEY_PATH.pub")"

    printf '  %sAuthorise this key ON THE VM%s\n\n' "$B" "$N"
    printf '  Once you are on the VM, run:\n\n'
    printf '    mkdir -p ~/.ssh && chmod 700 ~/.ssh\n'
    printf '    echo '"'"'%s'"'"' >> ~/.ssh/authorized_keys\n' "$(cat "$KEY_PATH.pub")"
    printf '    chmod 600 ~/.ssh/authorized_keys\n\n'
    printf '  %sThen, from Termux:%s\n\n' "$B" "$N"
    printf '    bash %s --connect <public-ip> --user %s\n\n' "$(basename "$0")" "$SSH_USER"
}

# ---------------------------------------------------------------------
# connect
# ---------------------------------------------------------------------

connect() {
    # Check if TARGET is an SSH config alias
    if [ -n "$TARGET" ] && [ -f "$HOME/.ssh/config" ]; then
        if grep -q "^Host $TARGET$" "$HOME/.ssh/config" 2>/dev/null; then
            step "connecting to $TARGET (using SSH config alias)"
            command -v ssh >/dev/null 2>&1 || die "ssh not installed"
            exec ssh "$TARGET"
        fi
    fi
    
    [ -n "$TARGET" ] || die "give an address: --connect 1.2.3.4 or --connect vm-alias"
    [ -f "$KEY_PATH" ] || die "no key at $KEY_PATH — run --setup-key first"
    chmod 600 "$KEY_PATH" 2>/dev/null || true

    command -v ssh >/dev/null 2>&1 || die "ssh not installed — run: pkg install openssh"

    step "connecting to $SSH_USER@$TARGET"
    info "using key: $KEY_PATH"

    case "$TARGET" in
        10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*)
            warn "$TARGET is a private address"
            warn "use public IP, or connect over Tailscale"
            ;;
    esac

    if ssh -i "$KEY_PATH" \
        -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=4 \
        "$SSH_USER@$TARGET"; then
        exit 0
    fi

    rc=$?
    printf '\n' >&2
    warn "connection failed (exit $rc)"
    exit "$rc"
}

# ---------------------------------------------------------------------
# trust-host
# ---------------------------------------------------------------------

trust_host() {
    local box="${BOX:-docker}"
    [ -n "$TARGET" ] || die "give an address: --trust-host 100.x.y.z"

    command -v rootd >/dev/null 2>&1 || die "rootd not found"
    rootd ls --plain 2>/dev/null | grep -qx "$box" \
        || die "no container named '$box' (use --box NAME)"

    local keys=""

    if [ -f "$HOME/.ssh/known_hosts" ]; then
        keys=$(ssh-keygen -F "$TARGET" -f "$HOME/.ssh/known_hosts" 2>/dev/null \
               | grep -v '^#' || true)
    fi

    if [ -n "$keys" ]; then
        step "reusing the host key you already verified"
    else
        step "scanning $TARGET for its $KEY_TYPE key"
        keys=$(ssh-keyscan -t "$KEY_TYPE" -T 10 "$TARGET" 2>/dev/null | grep -v '^#' || true)
        [ -n "$keys" ] || die "no $KEY_TYPE host key from $TARGET"

        printf '\n  %sFingerprint offered by %s:%s\n\n' "$B" "$TARGET" "$N"
        printf '%s' "$keys" | ssh-keygen -lf - 2>/dev/null | sed 's/^/    /' >&2
        printf '\n  %sThis was fetched over the network and is unverified.%s\n\n' "$Y" "$N"
    fi

    rootd sh "$box" -- sh -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh' \
        || die "could not prepare /root/.ssh inside '$box'"

    printf '%s\n' "$keys" | rootd sh "$box" -- \
        sh -c 'cat >> /root/.ssh/known_hosts && chmod 600 /root/.ssh/known_hosts' \
        || die "could not write known_hosts inside '$box'"

    step "'$box' now trusts $TARGET"
}

# ---------------------------------------------------------------------
# main
# ---------------------------------------------------------------------

case "$ACTION" in
    list)       list_instances ;;
    instances)  show_instances ;;
    profiles)   list_profiles ;;
    setupkey)   setup_key ;;
    connect)    connect ;;
    trusthost)  trust_host ;;
esac
