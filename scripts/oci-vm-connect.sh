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
#   bash oci-vm-connect.sh --trust-host <ip> let a rootd box trust the VM
#
# Requires a working OCI CLI:  bash termux-oci-cli.sh --check
#
set -euo pipefail

ACTION=""
TARGET=""
SSH_USER="ubuntu"
BOX="docker"
KEY_TYPE="ed25519"
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
        -h|--help)     sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=""; Y=""; R=""; C=""; D=""; B=""; N=""
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

    # JSON arrives on stdin. Interpolating it into the Python source
    # breaks on any control character, and an instance's
    # ssh_authorized_keys metadata ends with a literal newline — exactly
    # that case.
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

for inst in items:
    print("    %s" % inst.get("display-name", "?"))
    print("      shape  : %s" % inst.get("shape", "?"))
    ocid = inst.get("id", "")
    try:
        out = subprocess.run(
            ["oci", "compute", "instance", "list-vnics", "--instance-id", ocid],
            capture_output=True, text=True, timeout=90,
        )
        vnics = json.loads(out.stdout).get("data", []) if out.stdout.strip() else []
        for v in vnics:
            if v.get("public-ip"):
                print("      public : %s" % v["public-ip"])
            if v.get("private-ip"):
                print("      private: %s" % v["private-ip"])
    except Exception:
        print("      (could not read IPs)")
    print("      ocid   : %s..." % ocid[:50])
    print()
'

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

    # The Docker client runs inside a rootd box, which has its own
    # /root/.ssh. A key that exists only in Termux leaves ssh inside the
    # box with no identity — it then falls back to other auth methods and
    # blocks on a prompt that can never be answered, because stdin is
    # already carrying `docker system dial-stdio`. The symptom is a hang,
    # not an error, so copy the key in at the same time.
    if command -v rootd >/dev/null 2>&1 \
       && rootd ls --plain 2>/dev/null | grep -qx "$BOX"; then
        step "copying the key into the '$BOX' container"
        rootd sh "$BOX" -- sh -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh' \
            || warn "could not prepare /root/.ssh inside '$BOX'"
        if rootd sh "$BOX" -- sh -c \
             'cat > /root/.ssh/id_ed25519 && chmod 600 /root/.ssh/id_ed25519' \
             < "$KEY_PATH"; then
            info "private key installed in '$BOX'"
        else
            warn "could not copy the key into '$BOX'"
        fi
        printf '  %sThe key now exists in two places; rotating it means%s\n' "$D" "$N" >&2
        printf '  %sreplacing both, and 'rootd backup %s' will contain it.%s\n' \
            "$D" "$BOX" "$N" >&2
    fi

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

# ---------------------------------------------------------------------
# trust-host: teach a rootd box the VM's host key
# ---------------------------------------------------------------------
#
# `docker --host ssh://...` runs `ssh -T ... docker system dial-stdio`.
# With no TTY, ssh cannot ask whether to trust an unknown host key, so
# the very first connection fails with "Host key verification failed".
#
# The container also keeps its own known_hosts, separate from Termux's —
# verifying the host in Termux does nothing for the box.
trust_host() {
    local box="${BOX:-docker}"
    [ -n "$TARGET" ] || die "give an address: --trust-host 100.x.y.z"

    command -v rootd >/dev/null 2>&1 || die "rootd not found"
    rootd ls --plain 2>/dev/null | grep -qx "$box" \
        || die "no container named '$box' (use --box NAME)"

    local keys=""

    # Prefer the key you already verified. Termux's own known_hosts holds
    # exactly the key ssh accepted when you first connected, so copying
    # that across asks you to trust nothing new.
    if [ -f "$HOME/.ssh/known_hosts" ]; then
        keys=$(ssh-keygen -F "$TARGET" -f "$HOME/.ssh/known_hosts" 2>/dev/null \
               | grep -v '^#' || true)
    fi

    if [ -n "$keys" ]; then
        step "reusing the host key you already verified"
        printf '\n' >&2
        printf '%s' "$keys" | ssh-keygen -lf - 2>/dev/null | sed 's/^/    /' >&2
        printf '\n  %sTaken from your Termux known_hosts — nothing new to approve.%s\n\n' \
            "$D" "$N" >&2
    else
        # Nothing on file. Scan, but take only one key type: fetching every
        # type would have you approve keys you have never seen, which
        # defeats the point of checking.
        step "no local record — scanning $TARGET for its $KEY_TYPE key"
        keys=$(ssh-keyscan -t "$KEY_TYPE" -T 10 "$TARGET" 2>/dev/null | grep -v '^#' || true)
        [ -n "$keys" ] || die "no $KEY_TYPE host key from $TARGET (try --key-type rsa)"

        printf '\n  %sFingerprint offered by %s:%s\n\n' "$B" "$TARGET" "$N"
        printf '%s' "$keys" | ssh-keygen -lf - 2>/dev/null | sed 's/^/    /' >&2
        printf '\n  %sThis was fetched over the network and is unverified.%s\n' "$Y" "$N" >&2
        printf '  %sCompare it against the fingerprint shown the first time you\n' "$D" >&2
        printf '  ssh-ed in, or read it from the VM itself:%s\n\n' "$N" >&2
        printf '    ssh %s@%s "ssh-keygen -lf /etc/ssh/ssh_host_%s_key.pub"\n\n' \
            "$SSH_USER" "$TARGET" "$KEY_TYPE" >&2

        if [ -t 0 ]; then
            printf '  Does it match? [y/N] ' >&2
            read -r reply || reply=""
            case "$reply" in [Yy]*) ;; *) echo "  aborted" >&2; exit 1 ;; esac
        else
            die "refusing to trust an unverified key non-interactively"
        fi
    fi

    rootd sh "$box" -- sh -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh' \
        || die "could not prepare /root/.ssh inside '$box'"

    printf '%s\n' "$keys" | rootd sh "$box" -- \
        sh -c 'cat >> /root/.ssh/known_hosts && chmod 600 /root/.ssh/known_hosts' \
        || die "could not write known_hosts inside '$box'"

    step "'$box' now trusts $TARGET"

    # Trusting the host is only half of it. Without a private key in the
    # box, ssh has no identity and hangs instead of failing.
    if ! rootd sh "$box" -- test -f /root/.ssh/id_ed25519 2>/dev/null; then
        printf '\n' >&2
        warn "'$box' has no private key — ssh will hang rather than fail"
        printf '\n  Install it:\n' >&2
        printf '    cat ~/.ssh/id_ed25519 | rootd sh %s -- \\\n' "$box" >&2
        printf '      sh -c "cat > /root/.ssh/id_ed25519 && chmod 600 /root/.ssh/id_ed25519"\n' >&2
        printf '\n  Or re-run:  bash %s --setup-key\n' "$(basename "$0")" >&2
    fi

    printf '\n  Try it:\n    rootd sh %s -- docker version\n\n' "$box" >&2
}

case "$ACTION" in
    list)       list_instances ;;
    setupkey)   setup_key ;;
    connect)    connect ;;
    trusthost)  trust_host ;;
esac
