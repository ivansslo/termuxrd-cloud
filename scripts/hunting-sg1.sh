#!/usr/bin/env bash
#
# hunting-sg1.sh — Launch hunting-singapore-1 instance with VMX86 profile
#
# Usage:
#   bash scripts/hunting-sg1.sh
#
# Requires:
#   - OCI CLI configured: ~/.oci/config
#   - SSH key: ~/.ssh/id_ed25519
#   - Profile VMX86 in config
#
set -euo pipefail

NAME="hunting-sg1"
PROFILE="VMX86"
REGION="ap-singapore-1"

echo "=== Launching $NAME in $REGION with profile $PROFILE ==="

# Export region
export OCI_REGION="$REGION"

# Get credentials from profile
COMP=$(grep "^tenancy" ~/.oci/config | head -1 | cut -d= -f2)

# Get availability domain
AD=$(oci iam availability-domain list --profile "$PROFILE" --query 'data[0].name' --raw-output)

# Get subnet
SUBNET=$(oci network subnet list --compartment-id "$COMP" --profile "$PROFILE" \
  --query 'data[0].id' --raw-output)

# Get Ubuntu image for x86
IMAGE=$(oci compute image list --compartment-id "$COMP" --profile "$PROFILE" \
  --operating-system "Canonical Ubuntu" \
  --shape VM.Standard.E2.1.Micro \
  --sort-by TIMECREATED \
  --query 'data[0].id' --raw-output)

echo "Tenancy: $COMP"
echo "Availability Domain: $AD"
echo "Subnet: $SUBNET"
echo "Image: $IMAGE"

# Launch instance
oci compute instance launch \
  --availability-domain "$AD" \
  --compartment-id "$COMP" \
  --display-name "$NAME" \
  --shape VM.Standard.E2.1.Micro \
  --image-id "$IMAGE" \
  --subnet-id "$SUBNET" \
  --assign-public-ip true \
  --ssh-authorized-keys-file ~/.ssh/id_ed25519.pub \
  --profile "$PROFILE" \
  --wait-for-state RUNNING

echo "=== $NAME is RUNNING ==="

# Get IP and add to SSH config
IP=$(oci compute instance list-vnics --instance-id "$(oci compute instance list --compartment-id "$COMP" --profile "$PROFILE" --display-name "$NAME" --query 'data[0].id' --raw-output)" --query 'data[0]."public-ip"' --raw-output)

echo "Public IP: $IP"

# Add to SSH config
if [ -d "$HOME/.ssh" ]; then
    mkdir -p "$HOME/.ssh"
    if ! grep -q "Host $NAME" "$HOME/.ssh/config" 2>/dev/null; then
        cat >> "$HOME/.ssh/config" <<EOF

# $NAME - $REGION
Host $NAME
    HostName $IP
    User ubuntu
    Port 22
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
        echo "Added $NAME to ~/.ssh/config"
    fi
fi

echo ""
echo "Connect with: ssh $NAME"
