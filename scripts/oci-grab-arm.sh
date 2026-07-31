#!/usr/bin/env bash
#
# oci-grab-arm.sh - Best Hunting Script for OCI ARM (Singapore Optimized)
# Specs: 4 OCPU / 24 GB RAM
#
set -uo pipefail

# -- CONFIGURATION --
NAME="roc-master-ai"
OCPUS=4
MEM=24
INTERVAL=60 # Try every 60 seconds
BOOT_GB=50
PROFILE="${PROFILE:-DEFAULT}"
KEY_PUB="$HOME/.ssh/id_ed25519.pub"
# ------------------

G='\033[32m'; Y='\033[33m'; R='\033[31m'; C='\033[36m'; B='\033[1m'; N='\033[0m'
step() { printf '%s=>%s %s\n' "$G" "$N" "$*" >&2; }
info() { printf '%s::%s %s\n' "$C" "$N" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# Check Public Key
[ -f "$KEY_PUB" ] || die "SSH Public key not found at $KEY_PUB. Run setup-key first."

OCI_CMD="oci --profile $PROFILE"

step "Starting Hunter for Singapore (A1.Flex 4:24)"
info "Using Profile: $PROFILE"

# Get Tenancy
COMP=$(python3 - "$HOME/.oci/config" "$PROFILE" <<'PY'
import configparser, sys
p = configparser.ConfigParser()
p.read(sys.argv[1])
print(p[sys.argv[2]].get("tenancy", ""))
PY
)
[ -n "$COMP" ] || die "Could not read tenancy from config"

# Get AD
step "Listing Availability Domains..."
AD=$($OCI_CMD iam availability-domain list --query 'data[0].name' --raw-output)
[ -n "$AD" ] || die "Auth failed or AD not found"

# Get Subnet
step "Finding Subnet..."
SUBNET=$($OCI_CMD network subnet list --compartment-id "$COMP" --query 'data[0].id' --raw-output)
[ -n "$SUBNET" ] || die "No subnet found in tenancy"

# Get Image (Ubuntu ARM)
step "Finding latest Ubuntu ARM image..."
IMAGE=$($OCI_CMD compute image list --compartment-id "$COMP" \
  --operating-system "Canonical Ubuntu" --shape VM.Standard.A1.Flex \
  --sort-by TIMECREATED --query 'data[0].id' --raw-output)
[ -n "$IMAGE" ] || die "Ubuntu ARM image not found"

echo -e "\n${B}HUNTING STARTED${N}"
echo -e "Target: $OCPUS OCPU / $MEM GB RAM"
echo -e "AD    : $AD"
echo -e "Press Ctrl+C to stop\n"

attempt=0
while :; do
    attempt=$((attempt + 1))
    printf "[$(date +%T)] Attempt $attempt... "

    out=$($OCI_CMD compute instance launch \
      --availability-domain "$AD" \
      --compartment-id "$COMP" \
      --display-name "$NAME" \
      --shape VM.Standard.A1.Flex \
      --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM}" \
      --image-id "$IMAGE" \
      --subnet-id "$SUBNET" \
      --assign-public-ip true \
      --ssh-authorized-keys-file "$KEY_PUB" \
      --wait-for-state RUNNING 2>&1)
    
    status=$?

    if [ $status -eq 0 ]; then
        echo -e "${G}SUCCESS!${N}"
        step "Instance created and running!"
        termux-notification --title "OCI ALERT" --content "4x24 ARM Instance Created!" || true
        termux-vibrate -d 2000 || true
        exit 0
    fi

    if [[ "$out" == *"Out of host capacity"* ]]; then
        echo -e "${Y}No Capacity${N}"
    elif [[ "$out" == *"NotAuthenticated"* ]]; then
        echo -e "${R}AUTH ERROR${N}"
        die "Authentication failed. Check your API Key and Fingerprint."
    elif [[ "$out" == *"TooManyRequests"* ]] || [[ "$out" == *"429"* ]]; then
        echo -e "${Y}Rate Limited${N}"
        sleep 300 # Wait 5 mins if throttled
    else
        echo -e "${R}Other Error${N}"
        echo "$out"
        sleep 10
    fi

    sleep "$INTERVAL"
done
