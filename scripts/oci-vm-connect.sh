#!/usr/bin/env bash
#
# oci-vm-connect.sh — find your OCI instances and set up SSH from Termux.
#
# Uses the OCI CLI to discover instances and their IPs, then helps you
# authorise an SSH key so you get a real terminal instead of the
# browser console.
#
#   bash oci-vm-connect.sh --list            list instances and IPs
#   bash oci-vm-connect.sh --setup-key       create/show an SSH key to authorise
#   bash oci-vm-connect.sh --connect <ip>    ssh in
#
# Requires a working OCI CLI:  bash termux-oci-cli.sh --check
#
set -euo pipefail

ACTION=""
TARGET=""
SSH_USER="ubuntu"
KEY_PATH="$HOME/.ssh/id_ed25519"
COMPARTMENT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --list)        ACTION="list" ;;
        --setup-key)   ACTION="setupkey" ;;
        --connect)
            ACTION="connect"
            if [ $# -lt 2 ] || case "${2:-}" in -*) true ;; *) false ;; esac; then
                echo "error: --connect needs an address, e.g. --connect 1.2.3.4" >&2
                exit 2
            fi
            shift; TARGET="$1" ;;
        --connect=*)   ACTION="connect"; TARGET="${1#*=}" ;;
        --user)        shift; SSH_USER="${1:-ubuntu}" ;;
        --user=*)      SSH_USER="${1#*=}" ;;
        --key)         shift; KEY_PATH="${1:-$KEY_PATH}" ;;
        --key=*)       KEY_PATH="${1#*=}" ;;
        --compartment) shift; COMPARTMENT="${1:-}" ;;
        --compartment=*) COMPARTMENT="${1#*=}" ;;
        -h|--help)     sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=""; Y=""; R=""; C=""; B=""; N=""
fi
step() { printf '%s=>%s %s\n' "$G" "$N" "$*" >&2; }
info() { printf '%s::%s %s\n' "$C" "$N" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

[ -n "$ACTION" ] || { sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

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
print(p.defaults().get("tenancy", ""))
PY
}

list_instances() {
    need_oci
    local comp="${COMPARTMENT:-$(tenancy_ocid)}"
    [ -n "$comp" ] || die "no compartment; pass --compartment ocid1.compartment..."

    step "querying instances"
    info "compartment: ${comp:0:40}…"

    local json
    json=$(oci compute instance list --compartment-id "$comp" \
             --lifecycle-state RUNNING --all 2>/dev/null) || {
        warn "no instances in that compartment, or access denied"
        printf '\n  List your compartments with:\n' >&2
        printf '    oci iam compartment list --output table\n\n' >&2
        return 1
    }

    printf '\n  %sRunning instances%s\n\n' "$B" "$N"

    python3 - <<PY
import json, subprocess, sys
data = json.loads('''$json''' or '{"data":[]}')
items = data.get("data", [])
if not items:
    print("    none running")
    sys.exit(0)
for inst in items:
    name = inst.get("display-name", "?")
    ocid = inst.get("id", "")
    shape = inst.get("shape", "?")
    print(f"    {name}")
    print(f"      shape : {shape}")
    try:
        out = subprocess.run(
            ["oci", "compute", "instance", "list-vnics", "--instance-id", ocid],
            capture_output=True, text=True, timeout=60,
        )
        vnics = json.loads(out.stdout).get("data", []) if out.stdout else []
        for v in vnics:
            pub = v.get("public-ip")
            priv = v.get("private-ip")
            if pub:
                print(f"      public: {pub}")
            if priv:
                print(f"      private: {priv}")
    except Exception:
        print("      (could not read IPs)")
    print(f"      ocid  : {ocid[:50]}…")
    print()
PY
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

    printf '\n  %sAuthorise this key ON THE VM%s\n\n' "$B" "$N"
    printf '  %sNot in Cloud Shell.%s Cloud Shell is a separate machine; a key\n' "$R" "$N"
    printf '  added there gives you nothing on your instance.\n\n'
    printf '  Your shell prompt must show the VM, for example:\n'
    printf '    %sopc@roc-vm%s   or   %subuntu@myserver%s\n' "$C" "$N" "$C" "$N"
    printf '  %snot%s  %sivansuselo@cloudshell%s\n\n' "$R" "$N" "$Y" "$N"
    printf '  Once you are on the VM, run:\n\n'
    printf '    mkdir -p ~/.ssh && chmod 700 ~/.ssh\n'
    printf '    echo '"'"'%s'"'"' >> ~/.ssh/authorized_keys\n' "$(cat "$KEY_PATH.pub")"
    printf '    chmod 600 ~/.ssh/authorized_keys\n\n'
    printf '  %sHow do I get onto the VM the first time?%s\n' "$B" "$N"
    printf '    Use the key you chose when you created the instance:\n'
    printf '      ssh -i ~/.ssh/that-key.pem opc@<public-ip>\n'
    printf '    From Cloud Shell you can hop in the same way, then paste the\n'
    printf '    three lines above.\n\n'
    printf '  %sThen, from Termux:%s\n\n' "$B" "$N"
    printf '    bash %s --connect <public-ip> --user %s\n\n' "$(basename "$0")" "$SSH_USER"
}

# ---------------------------------------------------------------------
# connect
# ---------------------------------------------------------------------

connect() {
    [ -n "$TARGET" ] || die "give an address: --connect 1.2.3.4"
    [ -f "$KEY_PATH" ] || die "no key at $KEY_PATH — run --setup-key first"
    chmod 600 "$KEY_PATH" 2>/dev/null || true

    command -v ssh >/dev/null 2>&1 || die "ssh not installed — run: pkg install openssh"

    step "connecting to $SSH_USER@$TARGET"
    info "first connection will ask you to trust the host key"

    case "$TARGET" in
        10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*)
            warn "$TARGET is a private address"
            warn "reachable from inside the VCN, not from your phone"
            warn "use the public IP, or connect over Tailscale (chapter 1)"
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
    printf '\n  %sMost likely causes, in order:%s\n\n' "$B" "$N"
    printf '    1. The key was authorised in Cloud Shell, not on the VM.\n'
    printf '       Cloud Shell is a different machine. Check the prompt: it\n'
    printf '       must read %s%s@<vm-name>%s, not %s...@cloudshell%s.\n\n' \
        "$C" "$SSH_USER" "$N" "$Y" "$N"
    printf '    2. Wrong login user. Try the others:\n'
    printf '         opc       Oracle Linux\n'
    printf '         ubuntu    Ubuntu\n'
    printf '         ec2-user  Amazon Linux\n'
    printf '       e.g.  bash %s --connect %s --user opc\n\n' "$(basename "$0")" "$TARGET"
    printf '    3. Port 22 closed in the Security List for that subnet.\n\n'
    printf '  Diagnose with:\n'
    printf '    ssh -v -i %s %s@%s 2>&1 | grep -iE "offering|denied|authenticat"\n\n' \
        "$KEY_PATH" "$SSH_USER" "$TARGET"
    exit "$rc"
}

case "$ACTION" in
    list)     list_instances ;;
    setupkey) setup_key ;;
    connect)  connect ;;
esac
