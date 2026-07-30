#!/usr/bin/env bash
#
# termux-setup.sh - prepare the phone side.
#
# Run this IN TERMUX.
#
#   bash termux-setup.sh --host 100.101.102.103 --user ubuntu
#
# Installs termuxrd, creates a Docker client container, generates an SSH
# key, and wires DOCKER_HOST. It prints the public key for you to add to
# the VM; it cannot do that step for you.
#
set -euo pipefail

VM_IP=""
VM_USER="ubuntu"
BOX="docker"
ASSUME_YES=0
TERMUXRD_REF="v1.0.0"

while [ $# -gt 0 ]; do
    case "$1" in
        --host)   shift; VM_IP="${1:-}" ;;
        --host=*) VM_IP="${1#*=}" ;;
        --user)   shift; VM_USER="${1:-ubuntu}" ;;
        --user=*) VM_USER="${1#*=}" ;;
        --box)    shift; BOX="${1:-docker}" ;;
        --box=*)  BOX="${1#*=}" ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# ---------------------------------------------------------------------

if [ -z "${PREFIX:-}" ] || [ ! -d "${PREFIX:-/nonexistent}" ]; then
    warn "this does not look like Termux; continuing anyway"
fi

if [ -z "$VM_IP" ]; then
    if [ -t 0 ]; then
        printf '  VM tailnet address [100.x.y.z]: ' >&2
        read -r VM_IP || VM_IP=""
    fi
    [ -n "$VM_IP" ] || die "no address given - pass --host 100.x.y.z"
fi

case "$VM_IP" in
    100.*) ;;
    *) warn "$VM_IP is not a 100.x address; is that really the tailnet IP?" ;;
esac

cat >&2 <<PLAN

  ${B}termux-setup${N}

  VM address : $VM_IP
  VM user    : $VM_USER
  Container  : $BOX

  Will:
    1. install prerequisites (python, proot, git, curl, openssh)
    2. install termuxrd $TERMUXRD_REF and the rootd-fs engine
    3. create a '$BOX' container with the Docker client
    4. generate an SSH key inside it
    5. set DOCKER_HOST=ssh://$VM_USER@$VM_IP

  ${D}You will then need to copy one line to the VM by hand.${N}

PLAN

if [ "$ASSUME_YES" != 1 ]; then
    if [ -t 0 ]; then
        printf '  Continue? [Y/n] ' >&2
        read -r reply || reply=""
        case "$reply" in [Nn]*) echo "  aborted" >&2; exit 0 ;; esac
    else
        die "not a terminal - pass --yes"
    fi
fi

# ---------------------------------------------------------------------
# 1. prerequisites
# ---------------------------------------------------------------------

step "installing prerequisites"
if command -v pkg >/dev/null 2>&1; then
    pkg install -y python proot git curl openssh || die "pkg install failed"
else
    warn "no 'pkg' command; assuming prerequisites are present"
fi

# ---------------------------------------------------------------------
# 2. termuxrd
# ---------------------------------------------------------------------

if command -v rootd >/dev/null 2>&1; then
    info "rootd already installed [$(rootd --version 2>&1 | head -1)]"
else
    step "installing termuxrd $TERMUXRD_REF"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    curl -fsSL "https://raw.githubusercontent.com/ivansslo/termuxrd/$TERMUXRD_REF/install.sh" \
        -o "$TMP/install.sh" || die "could not download the termuxrd installer"
    bash "$TMP/install.sh" --yes --no-autostart --distro alpine \
        || die "termuxrd installation failed"
fi

command -v rootd >/dev/null 2>&1 || export PATH="${PREFIX:-$HOME/.local}/bin:$PATH"
command -v rootd >/dev/null 2>&1 || die "rootd is not on PATH"

# ---------------------------------------------------------------------
# 3. docker client container
# ---------------------------------------------------------------------

if rootd ls --plain 2>/dev/null | grep -qx "$BOX"; then
    info "container '$BOX' already exists"
else
    step "creating the '$BOX' container with the Docker client"
    rootd install docker --name "$BOX" || die "could not create the container"
fi

if ! rootd sh "$BOX" -- which ssh >/dev/null 2>&1; then
    step "adding the SSH client inside the container"
    rootd sh "$BOX" -- apk add --no-cache openssh-client 2>/dev/null \
        || warn "could not install openssh-client; docker over ssh:// will not work"
fi

# ---------------------------------------------------------------------
# 4. ssh key
# ---------------------------------------------------------------------

if rootd sh "$BOX" -- test -f /root/.ssh/id_ed25519 2>/dev/null; then
    info "SSH key already exists in the container"
else
    step "generating an SSH key inside the container"
    rootd sh "$BOX" -- sh -c '
        mkdir -p /root/.ssh && chmod 700 /root/.ssh &&
        ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -C termux-phone >/dev/null
    ' || die "ssh-keygen failed"
fi

PUBKEY="$(rootd sh "$BOX" -- cat /root/.ssh/id_ed25519.pub 2>/dev/null | tr -d '\r')"
[ -n "$PUBKEY" ] || die "could not read the generated public key"

# ---------------------------------------------------------------------
# 5. wire DOCKER_HOST
# ---------------------------------------------------------------------

step "pointing the Docker client at ssh://$VM_USER@$VM_IP"
rootd docker "$BOX" --host "ssh://$VM_USER@$VM_IP" >/dev/null

# convenience helpers
RC="$HOME/.bashrc"
if ! grep -q 'termuxrd-cloud helpers' "$RC" 2>/dev/null; then
    step "adding 'dock' and 'dc' helpers to $RC"
    cp -p "$RC" "$RC.bak" 2>/dev/null || true
    cat >> "$RC" <<EOF

# termuxrd-cloud helpers
dock() { rootd sh $BOX -- docker "\$@"; }
dc()   { rootd sh $BOX -- docker compose "\$@"; }
EOF
fi

# ---------------------------------------------------------------------

cat >&2 <<NEXT

  ${G}Phone side is ready.${N}

  ${B}One manual step remains.${N} On the VM, run:

    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    echo '$PUBKEY' >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

  Then test from here:

    rootd sh $BOX -- ssh -o StrictHostKeyChecking=accept-new $VM_USER@$VM_IP hostname
    rootd sh $BOX -- docker version

  ${D}After 'source ~/.bashrc' you can simply use:  dock ps${N}

NEXT
