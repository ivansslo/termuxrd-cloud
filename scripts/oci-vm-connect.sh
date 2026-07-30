#!/usr/bin/env bash
#
# oci-vm-connect.sh - find OCI instances and connect via SSH.
#
# Usage:
#   bash oci-vm-connect.sh --list            # list running instances
#   bash oci-vm-connect.sh --setup-key       # generate a key for OCI
#   bash oci-vm-connect.sh --connect <IP>    # SSH to a public IP
#
set -uo pipefail

ACTION=""
TARGET=""
PROFILE=""
COMPARTMENT=""
SSH_USER="ubuntu"
KEY_PATH="$HOME/.ssh/id_ed25519"
KEY_TYPE="ed25519"

while [ $# -gt 0 ]; do
    case "$1" in
        --list)        ACTION="list" ;;
        --instances)   ACTION="instances" ;;
        --setup-key)   ACTION="setupkey" ;;
        --connect)     
            shift
            ACTION="connect"
            TARGET="${1:-}" ;;
        --connect=*)   ACTION="connect"; TARGET="${1#*=}" ;;
        --trust-host)
            shift
            ACTION="trusthost"
            TARGET="${1:-}" ;;
        --trust-host=*) ACTION="trusthost"; TARGET="${1#*=}" ;;
        --profile)     shift; PROFILE="${1:-}" ;;
        --profile=*)   PROFILE="${1#*=}" ;;
        --compartment) shift; COMPARTMENT="${1:-}" ;;
        --compartment=*) COMPARTMENT="${1#*=}" ;;
        --user)        shift; SSH_USER="${1:-ubuntu}" ;;
        --user=*)      SSH_USER="${1#*=}" ;;
        --key)         shift; KEY_PATH="${1:-$KEY_PATH}" ;;
        --key=*)       KEY_PATH="${1#*=}" ;;
        -h|--help)     sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# Color output
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=""; Y=""; R=""; C=""; B=""; N=""
fi
step() { printf '%s=>%s %s\n' "$G" "$N" "$*" >&2; }
info() { printf '%s::%s %s\n' "$C" "$N" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

[ -n "$ACTION" ] || { sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# Build OCI command with optional profile
OCI_CMD="oci"
[ -n "$PROFILE" ] && OCI_CMD="oci --profile $PROFILE"

if [ -n "$PROFILE" ]; then
    info "using profile: $PROFILE"
fi

# ---------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------

need_oci() {
    command -v oci >/dev/null 2>&1 || die "oci not found - run: bash termux-oci-cli.sh"
}

tenancy_ocid() {
    python3 - "$HOME/.oci/config" "${PROFILE:-DEFAULT}" <<'PY' 2>/dev/null
import configparser, sys
p = configparser.ConfigParser()
p.read(sys.argv[1])
section = sys.argv[2]
if section in p:
    print(p[section].get("tenancy", ""))
elif 'DEFAULT' in p:
    print(p['DEFAULT'].get("tenancy", ""))
PY
}

list_profiles() {
    step "available OCI profiles in ~/.oci/config"
    echo ""
    python3 - "$HOME/.oci/config" <<'PY' 2>/dev/null
import configparser, sys
p = configparser.ConfigParser()
p.read(sys.argv[1])
for s in p.sections():
    print("  - %s" % s)
PY
    echo ""
    info "usage: --profile PROFILENAME"
}

list_instances() {
    need_oci
    local comp="${COMPARTMENT:-$(tenancy_ocid)}"
    [ -n "$comp" ] || die "no compartment; pass --compartment ocid1.compartment..."

    step "querying instances - profile: ${PROFILE:-DEFAULT}"
    info "compartment: ${comp:0:40}..."

    local json
    json=$($OCI_CMD compute instance list --compartment-id "$comp" --lifecycle-state RUNNING --all 2>/dev/null) || {
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
    print("    no running instances found")
    sys.exit(0)

for i in items:
    name = i.get("display-name", "unknown")
    ocid = i.get("id", "")
    shape = i.get("shape", "")
    region = i.get("region", "unknown")
    
    # query IP
    ip = "?"
    try:
        r = subprocess.run(["oci", "compute", "instance", "list-vnics", 
                            "--instance-id", ocid],
                           capture_output=True, text=True, timeout=10)
        v = json.loads(r.stdout)["data"]
        ip = v[0].get("public-ip", "-")
        priv = v[0].get("private-ip", "-")
    except:
        ip = "err"
        priv = "-"

    print("  %s%-15s%s  %s  %s (priv: %s)" % ("\033[1m", name, "\033[0m", shape, ip, priv))
    print("    %s" % ocid)
    print("")
'
}

show_instances() {
    need_oci
    local comp="${COMPARTMENT:-$(tenancy_ocid)}"
    [ -n "$comp" ] || die "no compartment"

    step "detailed instance listing - profile: ${PROFILE:-DEFAULT}"

    local json
    json=$($OCI_CMD compute instance list --compartment-id "$comp" --lifecycle-state RUNNING --all 2>/dev/null) || {
        warn "no instances found"
        return 1
    }

    printf '%s' "$json" | python3 -c '
import json, subprocess, sys

try:
    data = json.load(sys.stdin)
except:
    sys.exit(0)

for i in data.get("data", []):
    print("-" * 60)
    print("Name      : %s" % i.get("display-name"))
    print("Shape     : %s" % i.get("shape"))
    print("AD        : %s" % i.get("availability-domain"))
    print("OCID      : %s" % i.get("id"))
    
    try:
        r = subprocess.run(["oci", "compute", "instance", "list-vnics", 
                            "--instance-id", i.get("id")],
                           capture_output=True, text=True, timeout=10)
        v = json.loads(r.stdout)["data"][0]
        print("Public IP : %s" % v.get("public-ip", "none"))
        print("Private IP: %s" % v.get("private-ip", "none"))
    except:
        pass
'
    echo "-" * 60
}

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
    cat "$KEY_PATH.pub" | sed 's/^/    /'

    cat <<HINT

  ${B}Register this key on your OCI VM:${N}
    1. Open Cloud Shell or log in using your existing key
    2. Run:
       mkdir -p ~/.ssh && chmod 700 ~/.ssh
       echo '$(cat "$KEY_PATH.pub")' >> ~/.ssh/authorized_keys
       chmod 600 ~/.ssh/authorized_keys

HINT
}

connect() {
    # Check if TARGET is an SSH config alias
    if [ -n "$TARGET" ] && [ -f "$HOME/.ssh/config" ]; then
        if grep -q "^Host $TARGET$" "$HOME/.ssh/config" 2>/dev/null; then
            step "connecting to $TARGET - using SSH config alias"
            command -v ssh >/dev/null 2>&1 || die "ssh not installed"
            exec ssh "$TARGET"
        fi
    fi
    
    [ -n "$TARGET" ] || die "usage: --connect <PUBLIC_IP>"
    [ -f "$KEY_PATH" ] || die "no key at $KEY_PATH - run --setup-key first"
    chmod 600 "$KEY_PATH" 2>/dev/null || true

    command -v ssh >/dev/null 2>&1 || die "ssh not installed - run: pkg install openssh"

    step "connecting to $SSH_USER@$TARGET"
    info "using key: $KEY_PATH"

    case "$TARGET" in
        10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*)
            warn "$TARGET is a private address"
            info "this will only work if you are on the same Tailscale network"
            ;;
    esac

    # Connect
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_USER@$TARGET"
    rc=$?

    if [ $rc -ne 0 ] && [ $rc -ne 130 ]; then
        warn "connection failed - exit $rc"
        echo "  Try specifying a different user: --user opc"
        echo "  Or check if port 22 is open on the VM's public interface."
    fi
}

trust_host() {
    [ -n "$TARGET" ] || die "usage: --trust-host <IP>"
    command -v rootd >/dev/null 2>&1 || die "rootd not found"
    
    local box="docker"
    rootd ls --plain | grep -qx "$box" \
        || die "no container named '$box' - use --box NAME"

    step "adding $TARGET to the '$box' container's known_hosts"
    
    local keys
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
    fi

    printf '%s\n' "$keys" | rootd sh "$box" -- \
        sh -c 'mkdir -p /root/.ssh && cat >> /root/.ssh/known_hosts && chmod 600 /root/.ssh/known_hosts' \
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
