#!/usr/bin/env bash
#
# oci-env-to-config.sh — pull OCI variables from a .env file into ~/.oci/config
#
# Usage:
#   bash oci-env-to-config.sh .env PROFILENAME
#
set -euo pipefail

ENV_FILE="${1:-}"
PROFILE="${2:-}"

# Color output
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
else
    G=""; Y=""; R=""; C=""; B=""; N=""
fi
step() { printf '%s=>%s %s\n' "$G" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "env file not found: $ENV_FILE"
[ -n "$PROFILE" ] || die "profile name required: bash $0 .env PROFILENAME"

step "extracting OCI variables from $ENV_FILE"

# Extract variables from the file without sourcing it (safer)
# Supports both OCI_USER and user style
get_var() {
    local key="$1"
    grep -E "^(OCI_)?${key}=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | sed 's/[[:space:]]*#.*//' | xargs || echo ""
}

USER=$(get_var "USER")
TENANCY=$(get_var "TENANCY")
FINGERPRINT=$(get_var "FINGERPRINT")
REGION=$(get_var "REGION")
KEY_FILE=$(get_var "KEY_FILE")

[ -n "$USER" ] || die "OCI_USER not found in $ENV_FILE"
[ -n "$TENANCY" ] || die "OCI_TENANCY not found in $ENV_FILE"
[ -n "$FINGERPRINT" ] || die "OCI_FINGERPRINT not found in $ENV_FILE"
[ -n "$REGION" ] || die "OCI_REGION not found in $ENV_FILE"

# Default key file if not specified
if [ -z "$KEY_FILE" ]; then
    KEY_FILE="$HOME/.oci/oci_api_key.pem"
fi

# Resolve ~ in KEY_FILE
KEY_FILE="${KEY_FILE/#\~/$HOME}"

OCI_DIR="$HOME/.oci"
mkdir -p "$OCI_DIR"
CFG="$OCI_DIR/config"

# Create backup
[ -f "$CFG" ] && cp "$CFG" "$CFG.bak-$(date +%Y%m%d)"

step "updating profile [$PROFILE] in $CFG"

python3 - "$CFG" "$PROFILE" "$USER" "$TENANCY" "$FINGERPRINT" "$REGION" "$KEY_FILE" <<'PY'
import configparser, sys, os

path, profile = sys.argv[1], sys.argv[2]
user, tenancy, fingerprint, region, key_file = sys.argv[3:8]

parser = configparser.ConfigParser()
if os.path.exists(path):
    parser.read(path)

if profile not in parser:
    parser.add_section(profile)

parser[profile]['user'] = user
parser[profile]['tenancy'] = tenancy
parser[profile]['fingerprint'] = fingerprint
parser[profile]['region'] = region
parser[profile]['key_file'] = key_file

with open(path, 'w') as f:
    parser.write(f)
PY

step "done. verify with: oci iam region list --profile $PROFILE"
