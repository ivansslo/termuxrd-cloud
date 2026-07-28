#!/usr/bin/env bash
#
# oci-grab-arm.sh — retry an Always Free Ampere launch until capacity appears.
#
# "Out of capacity for shape VM.Standard.A1.Flex" means Oracle has no free
# ARM hosts right now. Nothing is misconfigured; the answer is to keep
# asking. This does that politely and tells you when it wins.
#
#   bash oci-grab-arm.sh                     # 4 OCPU / 24 GB, every 5 min
#   bash oci-grab-arm.sh --ocpus 1 --mem 6   # smaller: better odds
#   bash oci-grab-arm.sh --interval 120      # try more often
#   bash oci-grab-arm.sh --once              # single attempt, then stop
#
# Needs a working OCI CLI:  bash termux-oci-cli.sh --check
#
set -uo pipefail

NAME="roc-vm"
OCPUS=4
MEM=24
INTERVAL=300
MAX_TRIES=0          # 0 = forever
ONCE=0
KEY_PUB="$HOME/.ssh/id_ed25519.pub"
BOOT_GB=50

while [ $# -gt 0 ]; do
    case "$1" in
        --name)      shift; NAME="${1:-roc-vm}" ;;
        --name=*)    NAME="${1#*=}" ;;
        --ocpus)     shift; OCPUS="${1:-4}" ;;
        --ocpus=*)   OCPUS="${1#*=}" ;;
        --mem)       shift; MEM="${1:-24}" ;;
        --mem=*)     MEM="${1#*=}" ;;
        --interval)  shift; INTERVAL="${1:-300}" ;;
        --interval=*) INTERVAL="${1#*=}" ;;
        --max-tries) shift; MAX_TRIES="${1:-0}" ;;
        --boot-gb)   shift; BOOT_GB="${1:-50}" ;;
        --key)       shift; KEY_PUB="${1:-$KEY_PUB}" ;;
        --once)      ONCE=1 ;;
        -h|--help)   sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

command -v oci >/dev/null 2>&1 || die "oci not found — run: bash termux-oci-cli.sh"
[ -f "$KEY_PUB" ] || die "no public key at $KEY_PUB — run: ssh-keygen -t ed25519"

# ---------------------------------------------------------------------
# gather what a launch needs
# ---------------------------------------------------------------------

step "reading your tenancy"

COMP=$(python3 - "$HOME/.oci/config" <<'PY' 2>/dev/null
import configparser, sys
p = configparser.ConfigParser(); p.read(sys.argv[1])
print(p.defaults().get("tenancy", ""))
PY
)
[ -n "$COMP" ] || die "could not read tenancy from ~/.oci/config"

mapfile -t ADS < <(oci iam availability-domain list --query 'data[].name' --raw-output 2>/dev/null | tr -d '[],"' | grep -v '^$' | sed 's/^ *//')
[ "${#ADS[@]}" -gt 0 ] || die "could not list availability domains"

SUBNET=$(oci network subnet list --compartment-id "$COMP" \
           --query 'data[0].id' --raw-output 2>/dev/null)
[ -n "$SUBNET" ] && [ "$SUBNET" != "null" ] \
    || die "no subnet found — create a VCN first"

IMAGE=$(oci compute image list --compartment-id "$COMP" \
          --operating-system "Canonical Ubuntu" \
          --operating-system-version "24.04 Minimal aarch64" \
          --shape VM.Standard.A1.Flex --sort-by TIMECREATED \
          --query 'data[0].id' --raw-output 2>/dev/null)
if [ -z "$IMAGE" ] || [ "$IMAGE" = "null" ]; then
    IMAGE=$(oci compute image list --compartment-id "$COMP" \
              --operating-system "Canonical Ubuntu" \
              --shape VM.Standard.A1.Flex --sort-by TIMECREATED \
              --query 'data[0].id' --raw-output 2>/dev/null)
fi
[ -n "$IMAGE" ] && [ "$IMAGE" != "null" ] || die "no Ubuntu ARM image found"

cat >&2 <<PLAN

  ${B}Hunting for Always Free Ampere capacity${N}

  Instance : $NAME
  Shape    : VM.Standard.A1.Flex — $OCPUS OCPU, $MEM GB
  Boot     : $BOOT_GB GB
  Domains  : ${#ADS[@]} (${ADS[*]})
  Interval : ${INTERVAL}s
  Key      : $KEY_PUB

  ${C}Leave this running. Termux must stay awake:${N}
    termux-wake-lock          ${C}(and disable battery optimisation)${N}

PLAN

# ---------------------------------------------------------------------
# attempt loop
# ---------------------------------------------------------------------

attempt=0
start=$(date +%s)

while :; do
    attempt=$((attempt + 1))

    for ad in "${ADS[@]}"; do
        printf '  [%s] try %d, %s ... ' "$(date +%H:%M:%S)" "$attempt" "$ad" >&2

        out=$(oci compute instance launch \
                --availability-domain "$ad" \
                --compartment-id "$COMP" \
                --display-name "$NAME" \
                --shape VM.Standard.A1.Flex \
                --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM}" \
                --image-id "$IMAGE" \
                --subnet-id "$SUBNET" \
                --boot-volume-size-in-gbs "$BOOT_GB" \
                --assign-public-ip true \
                --ssh-authorized-keys-file "$KEY_PUB" \
                --wait-for-state RUNNING \
                2>&1)
        rc=$?

        if [ $rc -eq 0 ]; then
            printf '%sGOT IT%s\n\n' "$G" "$N" >&2
            elapsed=$(( $(date +%s) - start ))
            step "instance created after ${attempt} attempt(s), ${elapsed}s"

            ip=$(echo "$out" | python3 -c '
import json, subprocess, sys
try:
    d = json.load(sys.stdin)
    ocid = d["data"]["id"]
except Exception:
    sys.exit(0)
try:
    r = subprocess.run(["oci","compute","instance","list-vnics",
                        "--instance-id",ocid],
                       capture_output=True, text=True, timeout=60)
    v = json.loads(r.stdout)["data"]
    print(v[0].get("public-ip",""))
except Exception:
    pass
' 2>/dev/null)

            printf '\n' >&2
            if [ -n "$ip" ]; then
                printf '  %sPublic IP: %s%s\n\n' "$B" "$ip" "$N" >&2
                printf '  Connect:\n' >&2
                printf '    ssh -i %s ubuntu@%s\n\n' "${KEY_PUB%.pub}" "$ip" >&2
            else
                printf '  Find the IP with:  bash oci-vm-connect.sh --list\n\n' >&2
            fi

            command -v termux-notification >/dev/null 2>&1 && \
                termux-notification --title "OCI capacity found" \
                  --content "$NAME is running${ip:+ at $ip}" 2>/dev/null || true
            command -v termux-vibrate >/dev/null 2>&1 && termux-vibrate -d 1000 2>/dev/null || true
            exit 0
        fi

        case "$out" in
            *"Out of capacity"*|*"Out of host capacity"*)
                printf '%sno capacity%s\n' "$Y" "$N" >&2 ;;
            *LimitExceeded*|*"limit"*)
                printf '%sQUOTA%s\n\n' "$R" "$N" >&2
                warn "you are at your Always Free limit"
                printf '\n  Total across all A1 instances: 4 OCPU and 24 GB.\n' >&2
                printf '  An old instance is probably still holding it. Check:\n\n' >&2
                printf '    oci compute instance list --compartment-id "$COMP" --output table\n\n' >&2
                exit 1 ;;
            *NotAuthenticated*|*NotAuthorized*)
                printf '%sAUTH%s\n\n' "$R" "$N" >&2
                warn "authentication failed"
                printf '\n  Check with:  bash termux-oci-cli.sh --check\n\n' >&2
                exit 1 ;;
            *)
                printf '%serror%s\n' "$R" "$N" >&2
                echo "$out" | tail -3 | sed 's/^/      /' >&2 ;;
        esac
    done

    if [ "$ONCE" = 1 ]; then
        warn "no capacity on this pass; --once was given, stopping"
        exit 1
    fi
    if [ "$MAX_TRIES" -gt 0 ] && [ "$attempt" -ge "$MAX_TRIES" ]; then
        warn "gave up after $attempt attempts"
        exit 1
    fi

    sleep "$INTERVAL"
done
