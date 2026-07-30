#!/usr/bin/env bash
#
# oci-grab-arm.sh  retry an Always Free Ampere launch until capacity appears.
#
# Supports multiple OCI profiles for managing different instances.
#
#   bash oci-grab-arm.sh                     # default profile
#   bash oci-grab-arm.sh --profile VMX86     # specific OCI profile
#   bash oci-grab-arm.sh --name hunting-sg1 # custom instance name
#   bash oci-grab-arm.sh --ocpus 1 --mem 6  # smaller: better odds
#   bash oci-grab-arm.sh --interval 120      # try more often
#   bash oci-grab-arm.sh --once              # single attempt, then stop
#
# Multiple profiles in ~/.oci/config:
#   [VMX86]   - x86 instances (E2.1.Micro)
#   [ARM]     - ARM instances (A1.Flex)
#   [ADMIN]   - primary admin account
#
set -uo pipefail

NAME="roc-vm"
OCPUS=4
MEM=24
INTERVAL=300
MAX_TRIES=0
ONCE=0
KEY_PUB="$HOME/.ssh/id_ed25519.pub"
BOOT_GB=50
PROFILE=""
REGION=""

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
        --profile)   shift; PROFILE="${1:-}" ;;
        --profile=*) PROFILE="${1#*=}" ;;
        --region)    shift; REGION="${1:-}" ;;
        --region=*)  REGION="${1#*=}" ;;
        --once)      ONCE=1 ;;
        -h|--help)   sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# Color output
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=""; Y=""; R=""; C=""; B=""; N=""
fi
step() { printf '%s=>%s %s\n' "$G" "$N" "$*" >&2; }
info() { printf '%s::%s %s\n' "$C" "$N" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

command -v oci >/dev/null 2>&1 || die "oci not found  run: bash termux-oci-cli.sh"

if [ -n "$PROFILE" ]; then
    info "using profile: $PROFILE"
fi

if [ -n "$REGION" ]; then
    export OCI_REGION="$REGION"
    info "using region: $REGION"
fi

# Build OCI command with optional profile
OCI_CMD="oci"
[ -n "$PROFILE" ] && OCI_CMD="$OCI_CMD --profile $PROFILE"

if [ "$INTERVAL" -lt 300 ] 2>/dev/null; then
    warn "an interval under 5 minutes invites rate limiting"
fi
[ -f "$KEY_PUB" ] || die "no public key at $KEY_PUB  run: ssh-keygen -t ed25519"

# ---------------------------------------------------------------------
# gather what a launch needs
# ---------------------------------------------------------------------

step "reading your tenancy"

COMP=$(python3 - "$HOME/.oci/config" <<'PY' 2>/dev/null
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
)
[ -n "$COMP" ] || die "could not read tenancy from ~/.oci/config"

# Read region from profile if not specified
if [ -z "$REGION" ]; then
    REGION=$(python3 - "$HOME/.oci/config" <<'PY' 2>/dev/null
import configparser, sys
p = configparser.ConfigParser()
p.read(sys.argv[1])
section = sys.argv[2] if len(sys.argv) > 2 else 'DEFAULT'
if section in p:
    print(p[section].get("region", ""))
elif 'DEFAULT' in p:
    print(p['DEFAULT'].get("region", ""))
PY
"${PROFILE:-}"
)
fi

if [ -n "$REGION" ]; then
    export OCI_REGION="$REGION"
fi

info "region: ${REGION:-default}"

# List availability domains
ADS=()
while IFS= read -r ad; do
    [ -n "$ad" ] && ADS+=("$ad")
done < <(eval "$OCI_CMD iam availability-domain list --query 'data[].name' --raw-output 2>/dev/null | tr -d '[],\"' | grep -v '^$' | sed 's/^ *//')

[ "${#ADS[@]}" -gt 0 ] || die "could not list availability domains"

SUBNET=$(eval "$OCI_CMD network subnet list --compartment-id \"$COMP\" \
           --query 'data[0].id' --raw-output 2>/dev/null")
[ -n "$SUBNET" ] && [ "$SUBNET" != "null" ] \
    || die "no subnet found  create a VCN first"

IMAGE=$(eval "$OCI_CMD compute image list --compartment-id \"$COMP\" \
          --operating-system \"Canonical Ubuntu\" \
          --operating-system-version \"24.04 Minimal aarch64\" \
          --shape VM.Standard.A1.Flex --sort-by TIMECREATED \
          --query 'data[0].id' --raw-output 2>/dev/null")
if [ -z "$IMAGE" ] || [ "$IMAGE" = "null" ]; then
    IMAGE=$(eval "$OCI_CMD compute image list --compartment-id \"$COMP\" \
              --operating-system \"Canonical Ubuntu\" \
              --shape VM.Standard.A1.Flex --sort-by TIMECREATED \
              --query 'data[0].id' --raw-output 2>/dev/null")
fi
[ -n "$IMAGE" ] && [ "$IMAGE" != "null" ] || die "no Ubuntu ARM image found"

cat >&2 <<PLAN

  ${B}Hunting for Always Free Ampere capacity${N}

  Instance : $NAME
  Shape    : VM.Standard.A1.Flex  $OCPUS OCPU, $MEM GB
  Boot     : $BOOT_GB GB
  Region   : ${REGION:-default}
  Profile  : ${PROFILE:-DEFAULT}
  Domains  : ${#ADS[@]} (${ADS[*]})
  Interval : ${INTERVAL}s
  Key      : $KEY_PUB

PLAN

if [ "${#ADS[@]}" -eq 1 ] && [ "$OCPUS" -gt 1 ]; then
    cat >&2 <<HINT
  ${Y}Your region has a single availability domain${N}, so there is nothing
  to rotate through. The only way to improve the odds is to ask for less.

    ${C}bash $(basename "$0") --profile $PROFILE --ocpus 1 --mem 6${N}

HINT
fi

cat >&2 <<WAKE
  ${C}Leave this running. Termux must stay awake:${N}
    termux-wake-lock

WAKE

# ---------------------------------------------------------------------
# attempt loop
# ---------------------------------------------------------------------

attempt=0
throttled=0
start=$(date +%s)

while :; do
    attempt=$((attempt + 1))

    for ad in "${ADS[@]}"; do
        printf '  [%s] try %d, %s ... ' "$(date +%H:%M:%S)" "$attempt" "$ad" >&2

        out=$($OCI_CMD compute instance launch --availability-domain "$ad" --compartment-id "$COMP" --display-name "$NAME" --shape VM.Standard.A1.Flex --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM}" --image-id "$IMAGE" --subnet-id "$SUBNET" --boot-volume-size-in-gbs "$BOOT_GB" --assign-public-ip true --ssh-authorized-keys-file "$KEY_PUB" --wait-for-state RUNNING 2>&1)
        rc=$?

        if [ $rc -eq 0 ]; then
            printf '%sGOT IT%s\n\n' "$G" "$N" >&2
            elapsed=$(( $(date +%s) - start ))
            step "instance created after ${attempt} attempts, ${elapsed}s"

            # Get public IP
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

            # Add to SSH config
            if [ -d "$HOME/.ssh" ] && [ -f "$HOME/.ssh/config" ]; then
                if ! grep -q "Host $NAME" "$HOME/.ssh/config" 2>/dev/null; then
                    cat >> "$HOME/.ssh/config" <<EOF

# $NAME - $REGION
Host $NAME
    HostName ${ip:-<IP>}
    User ubuntu
    Port 22
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
                    step "added $NAME to ~/.ssh/config"
                fi
            fi

            command -v termux-notification >/dev/null 2>&1 && \
                termux-notification --title "OCI capacity found" \
                  --content "$NAME is running${ip:+ at $ip}" 2>/dev/null || true
            command -v termux-vibrate >/dev/null 2>&1 && termux-vibrate -d 1000 2>/dev/null || true
            exit 0
        fi

        case "$out" in
            *"Out of capacity"*|*"Out of host capacity"*)
                throttled=0
                printf '%sno capacity%s\n' "$Y" "$N" >&2 ;;
            *LimitExceeded*|*"limit"*)
                printf '%sQUOTA%s\n\n' "$R" "$N" >&2
                warn "you are at your Always Free limit"
                exit 1 ;;
            *NotAuthenticated*|*"NotAuthorized"*)
                printf '%sAUTH%s\n\n' "$R" "$N" >&2
                warn "authentication failed"
                exit 1 ;;
            *TooManyRequests*|*": 429"*)
                throttled=$((throttled + 1))
                backoff=$(( 120 * (2 ** (throttled - 1)) ))
                [ "$backoff" -gt 1800 ] && backoff=1800
                printf '%srate limited%s\n' "$Y" "$N" >&2
                warn "throttled ${throttled}x  waiting $((backoff / 60)] min"
                sleep "$backoff"
                continue ;;
            *)
                printf '%serror%s\n' "$R" "$N" >&2 ;;
        esac
    done

    if [ $((attempt % 12)) -eq 0 ]; then
        mins=$(( ( $(date +%s) - start ) / 60 ))
        info "still hunting  $attempt attempts over ${mins} min"
    fi

    [ "$ONCE" = 1 ] && warn "no capacity; --once was given, stopping" && exit 1
    [ "$MAX_TRIES" -gt 0 ] && [ "$attempt" -ge "$MAX_TRIES" ] && warn "gave up after $attempt attempts" && exit 1

    sleep "$INTERVAL"
done
