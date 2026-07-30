#!/usr/bin/env bash
#
# server-bootstrap.sh - install Tailscale and Docker on a cloud VM.
#
# Run this ON THE VM, not on your phone.
#
#   bash server-bootstrap.sh --hostname myserver
#   bash server-bootstrap.sh --hostname myserver --authkey tskey-auth-...
#
# It shows what it will do and asks before doing it. Nothing is
# installed twice; re-running is safe.
#
set -euo pipefail

HOSTNAME_TS=""
AUTHKEY=""
ASSUME_YES=0
SKIP_DOCKER=0
SKIP_TAILSCALE=0
ADD_SWAP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --hostname)  shift; HOSTNAME_TS="${1:-}" ;;
        --hostname=*) HOSTNAME_TS="${1#*=}" ;;
        --authkey)   shift; AUTHKEY="${1:-}" ;;
        --authkey=*) AUTHKEY="${1#*=}" ;;
        --swap)          ADD_SWAP=1 ;;
        --no-docker)     SKIP_DOCKER=1 ;;
        --no-tailscale)  SKIP_TAILSCALE=1 ;;
        -y|--yes)        ASSUME_YES=1 ;;
        -h|--help)   sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
else
    G=""; Y=""; R=""; C=""; D=""; N=""
fi
step() { printf '%s=>%s %s\n' "$G" "$N" "$*" >&2; }
info() { printf '%s::%s %s\n' "$C" "$N" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] && warn "running as root; the docker group step will be skipped"

command -v sudo >/dev/null 2>&1 || die "sudo is required"

# ---------------------------------------------------------------------
# detect platform
# ---------------------------------------------------------------------

KERNEL="$(uname -r)"
case "$KERNEL" in
    *-oracle*) CLOUD="Oracle Cloud" ;;
    *-aws*)    CLOUD="AWS EC2" ;;
    *-azure*)  CLOUD="Azure" ;;
    *-gcp*)    CLOUD="Google Cloud" ;;
    *)         CLOUD="generic Linux" ;;
esac

DISTRO="unknown"
[ -r /etc/os-release ] && . /etc/os-release && DISTRO="${ID:-unknown}"

cat >&2 <<PLAN

  ${C}server-bootstrap${N}

  Detected  : $CLOUD  ($DISTRO, kernel $KERNEL)
  Hostname  : ${HOSTNAME_TS:-<will prompt>}

  Will install:
$( ( "$SKIP_TAILSCALE" = 0 ) && echo "    - Tailscale, and join your tailnet" )
$( ( "$SKIP_DOCKER" = 0 )    && echo "    - Docker Engine + Compose, socket-only (no TCP port)" )
$( ( "$ADD_SWAP" = 1 )       && echo "    - 2 GB swap file" )

  ${D}No inbound firewall ports are opened. Nothing listens publicly.${N}

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
# tailscale
# ---------------------------------------------------------------------

if [ "$SKIP_TAILSCALE" = 0 ]; then
    if command -v tailscale >/dev/null 2>&1; then
        info "tailscale already installed [$(tailscale version | head -1)]"
    else
        step "installing tailscale"
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    if tailscale status >/dev/null 2>&1; then
        info "already connected to a tailnet"
    else
        if [ -z "$HOSTNAME_TS" ]; then
            if [ -t 0 ]; then
                printf '  Tailnet hostname for this machine: ' >&2
                read -r HOSTNAME_TS || HOSTNAME_TS=""
            fi
            [ -n "$HOSTNAME_TS" ] || HOSTNAME_TS="$(hostname -s)"
        fi

        step "joining the tailnet as '$HOSTNAME_TS'"
        if [ -n "$AUTHKEY" ]; then
            sudo tailscale up --ssh --hostname="$HOSTNAME_TS" --authkey="$AUTHKEY"
        else
            info "a login URL will be printed - open it in a browser"
            sudo tailscale up --ssh --hostname="$HOSTNAME_TS"
        fi
    fi

    sudo systemctl enable --now tailscaled >/dev/null 2>&1 || \
        warn "could not enable tailscaled at boot"

    TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    [ -n "$TS_IP" ] && step "tailnet address: $TS_IP"
fi

# ---------------------------------------------------------------------
# docker
# ---------------------------------------------------------------------

if [ "$SKIP_DOCKER" = 0 ]; then
    if command -v docker >/dev/null 2>&1; then
        info "docker already installed [$(docker --version)]"
    else
        step "installing docker engine"
        case "$DISTRO" in
            ol|oracle|rhel|centos|rocky|almalinux)
                sudo dnf install -y dnf-utils
                sudo dnf config-manager --add-repo \
                    https://download.docker.com/linux/centos/docker-ce.repo
                sudo dnf install -y docker-ce docker-ce-cli containerd.io \
                    docker-buildx-plugin docker-compose-plugin
                ;;
            *)
                curl -fsSL https://get.docker.com | sh
                ;;
        esac
    fi

    sudo systemctl enable --now docker containerd >/dev/null 2>&1 || \
        warn "could not enable docker at boot"

    if [ "$(id -u)" -ne 0 ]; then
        if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
            info "$USER is already in the docker group"
        else
            step "adding $USER to the docker group"
            sudo usermod -aG docker "$USER"
            warn "log out and back in for this to take effect"
            warn "the docker group is equivalent to root on this host"
        fi
    fi

    # Log rotation: unbounded logs fill small boot volumes.
    if [ ! -f /etc/docker/daemon.json ]; then
        step "capping container log size"
        sudo mkdir -p /etc/docker
        printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "3" }\n}\n' \
            | sudo tee /etc/docker/daemon.json >/dev/null
        sudo systemctl restart docker || warn "docker restart failed"
    fi

    # Refuse to leave a public daemon port open.
    if sudo ss -tlnp 2>/dev/null | grep -qE ':(2375|2376)\b'; then
        warn "the Docker daemon is listening on a TCP port!"
        warn "that is an unauthenticated root shell for anyone who can reach it"
        warn "remove -H tcp://... from the daemon configuration"
    fi
fi

# ---------------------------------------------------------------------
# swap
# ---------------------------------------------------------------------

if [ "$ADD_SWAP" = 1 ]; then
    if swapon --show 2>/dev/null | grep -q .; then
        info "swap already configured"
    else
        step "creating a 2 GB swap file"
        sudo fallocate -l 2G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile >/dev/null
        sudo swapon /swapfile
        grep -q '^/swapfile' /etc/fstab || \
            echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    fi
fi

# ---------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------

TS_IP="${TS_IP:-$(tailscale ip -4 2>/dev/null | head -1 || echo '<not connected>')}"

cat >&2 <<DONE

  ${G}Server ready.${N}

  Tailnet address : ${C}$TS_IP${N}
  Login user      : ${C}${USER}${N}

  ${D}Next, on your phone:${N}

    rootd docker docker --host ssh://${USER}@${TS_IP}
    rootd sh docker -- docker ps

  ${D}Do not forget:${N}
    - disable key expiry in the Tailscale admin console
      (Machines -> your machine -> ... -> Disable key expiry)
    - once tailnet SSH works, remove public port 22 from your
      Security List (OCI) or Security Group (AWS)

DONE
