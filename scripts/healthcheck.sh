#!/usr/bin/env bash
#
# healthcheck.sh - find out which layer is broken.
#
# Run this IN TERMUX.
#
#   bash healthcheck.sh                       # uses the box's own DOCKER_HOST
#   bash healthcheck.sh --host 100.x.y.z --user ubuntu
#
# Read-only: it changes nothing.
#
set -uo pipefail          # deliberately not -e; we want every check to run

BOX="docker"
VM_IP=""
VM_USER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --host)   shift; VM_IP="${1:-}" ;;
        --host=*) VM_IP="${1#*=}" ;;
        --user)   shift; VM_USER="${1:-}" ;;
        --user=*) VM_USER="${1#*=}" ;;
        --box)    shift; BOX="${1:-docker}" ;;
        --box=*)  BOX="${1#*=}" ;;
        -h|--help) sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=""; R=""; Y=""; D=""; B=""; N=""
fi

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  %s-%s %s\n' "$Y" "$N" "$*"; SKIP=$((SKIP+1)); }
hint() { printf '      %s%s%s\n' "$D" "$*" "$N"; }

printf '\n%stermuxrd-cloud healthcheck%s\n\n' "$B" "$N"

# ---------------------------------------------------------------------
printf '%s1. phone tooling%s\n' "$B" "$N"

if command -v rootd >/dev/null 2>&1; then
    ok "rootd installed ($(rootd --version 2>&1 | head -1))"
else
    bad "rootd not found"
    hint "run: bash scripts/termux-setup.sh"
    printf '\n  Cannot continue without rootd.\n\n'
    exit 1
fi

if rootd ls --plain 2>/dev/null | grep -qx "$BOX"; then
    ok "container '$BOX' exists"
else
    bad "no container named '$BOX'"
    hint "run: rootd install docker --name $BOX"
fi

if rootd sh "$BOX" -- which docker >/dev/null 2>&1; then
    ok "docker client present in the container"
else
    bad "docker client missing inside '$BOX'"
    hint "run: rootd sh $BOX -- apk add --no-cache docker-cli"
fi

if rootd sh "$BOX" -- which ssh >/dev/null 2>&1; then
    ok "ssh client present in the container"
else
    bad "ssh client missing inside '$BOX'"
    hint "run: rootd sh $BOX -- apk add --no-cache openssh-client"
fi

# ---------------------------------------------------------------------
printf '\n%s2. configuration%s\n' "$B" "$N"

CONFIGURED="$(rootd docker "$BOX" 2>&1 | grep -oE 'ssh://[^ ]+' | head -1)"
if [ -n "$CONFIGURED" ]; then
    ok "DOCKER_HOST = $CONFIGURED"
    if [ -z "$VM_IP" ]; then
        VM_IP="${CONFIGURED##*@}"
        VM_USER="${CONFIGURED#ssh://}"; VM_USER="${VM_USER%@*}"
    fi
else
    bad "no DOCKER_HOST configured for '$BOX'"
    hint "run: rootd docker $BOX --host ssh://user@100.x.y.z"
fi

[ -n "$VM_USER" ] || VM_USER="ubuntu"

# ---------------------------------------------------------------------
printf '\n%s3. network%s\n' "$B" "$N"

if [ -z "$VM_IP" ]; then
    skip "no VM address known; pass --host"
else
    case "$VM_IP" in
        100.*) ok "$VM_IP is in the Tailscale range" ;;
        *)     skip "$VM_IP is not a 100.x address - is Tailscale in use?" ;;
    esac

    if ping -c 2 -W 3 "$VM_IP" >/dev/null 2>&1; then
        ok "VM responds to ping"
    else
        bad "no ping response from $VM_IP"
        hint "is Tailscale connected on both ends? has the node key expired?"
    fi
fi

# ---------------------------------------------------------------------
printf '\n%s4. ssh%s\n' "$B" "$N"

if [ -z "$VM_IP" ]; then
    skip "no VM address"
elif ! rootd sh "$BOX" -- test -f /root/.ssh/id_ed25519 2>/dev/null; then
    bad "no private key inside '$BOX'"
    hint "ssh will HANG rather than fail: it has no identity to offer,"
    hint "and cannot prompt because stdin carries docker dial-stdio"
    hint "fix: cat ~/.ssh/id_ed25519 | rootd sh $BOX -- \\"
    hint "       sh -c 'cat > /root/.ssh/id_ed25519 && chmod 600 /root/.ssh/id_ed25519'"
elif true; then
    ok "SSH key exists in the container"

    if rootd sh "$BOX" -- ssh -o BatchMode=yes -o ConnectTimeout=10 \
         -o StrictHostKeyChecking=accept-new "$VM_USER@$VM_IP" true 2>/dev/null; then
        ok "SSH to $VM_USER@$VM_IP works"
    else
        bad "SSH to $VM_USER@$VM_IP failed"
        hint "is the public key in the VM's ~/.ssh/authorized_keys?"
        hint "see it with: rootd sh $BOX -- cat /root/.ssh/id_ed25519.pub"
    fi
else
    bad "no SSH key in the container"
    hint "run: rootd ssh $BOX --keygen"
fi

# ---------------------------------------------------------------------
printf '\n%s5. docker daemon%s\n' "$B" "$N"

if rootd sh "$BOX" -- docker version >/dev/null 2>&1; then
    SRV="$(rootd sh "$BOX" -- docker version --format '{{.Server.Version}}' 2>/dev/null | tr -d '\r')"
    ok "daemon reachable (server ${SRV:-unknown})"

    RUNNING="$(rootd sh "$BOX" -- docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
    ok "$RUNNING container(s) running on the VM"
else
    bad "cannot reach the Docker daemon"
    hint "on the VM: systemctl is-active docker"
    hint "on the VM: groups   (your user must be in 'docker')"
fi

# ---------------------------------------------------------------------
printf '\n%s6. this device%s\n' "$B" "$N"

if rootd caps 2>&1 | grep -q "No local Docker daemon"; then
    ok "local daemon correctly reported as impossible (expected on Android)"
else
    skip "kernel appears to support a local daemon - unusual for a phone"
fi

# ---------------------------------------------------------------------
printf '\n%ssummary%s  %s%d passed%s, %s%d failed%s, %d skipped\n\n' \
    "$B" "$N" "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$SKIP"

if [ "$FAIL" -gt 0 ]; then
    printf '  See docs/06-troubleshooting.md\n\n'
    exit 1
fi
printf '  %sEverything checks out.%s\n\n' "$G" "$N"
