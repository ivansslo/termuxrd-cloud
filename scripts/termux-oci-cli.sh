#!/usr/bin/env bash
#
# termux-oci-cli.sh — install the OCI CLI on Termux.
#
# Oracle's own install.sh cannot work here: it looks for dnf/yum/apt-get,
# finds none of them, and exits. This script does the equivalent using
# Termux's `pkg`, and works around a compile failure in `crc32c`.
#
#   bash termux-oci-cli.sh                  # install
#   bash termux-oci-cli.sh --check          # verify an existing install
#   bash termux-oci-cli.sh --repair-config  # fix a mangled ~/.oci/config
#   bash termux-oci-cli.sh --yes            # no prompts
#
# Read it before running it.
#
set -euo pipefail

ASSUME_YES=0
CHECK_ONLY=0
REPAIR_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)         ASSUME_YES=1 ;;
        --check)          CHECK_ONLY=1 ;;
        --repair-config)  REPAIR_ONLY=1 ;;
        -h|--help) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

OCI_DIR="$HOME/.oci"

# Read one key from the OCI config, the same way the SDK does.
#
# Two things this must survive:
#   * a key that is absent — grep would return 1 and, under `set -e`,
#     kill the script silently mid-report;
#   * a value wrapped in quotes or trailed by a comment, which the SDK
#     treats literally and which therefore must be reported as-is.
config_value() {
    local key="$1" file="$OCI_DIR/config"
    [ -f "$file" ] || return 0
    python3 - "$file" "$key" <<'PYCFG' 2>/dev/null || true
import configparser, sys
path, key = sys.argv[1], sys.argv[2]
parser = configparser.ConfigParser()
try:
    parser.read(path)
except configparser.Error:
    sys.exit(0)
value = ""
if parser.has_section("DEFAULT") or parser.defaults():
    value = parser.defaults().get(key, "")
for section in parser.sections():
    if not value:
        value = parser[section].get(key, "")
print(value.strip())
PYCFG
}

# Derive the OCI fingerprint (MD5 of the DER public key) from a private key.
#
# Deliberately not parsing `openssl md5 -c` output: some builds print
# "MD5(stdin)=aa:bb" with no space, which breaks field-splitting, and an
# encrypted key yields the hash of *empty input* (d41d8cd9...) — a wrong
# answer that looks like a right one. Python's cryptography module is
# already present because oci-cli depends on it.
key_fingerprint() {
    local keyfile="$1"
    [ -f "$keyfile" ] || return 0
    python3 - "$keyfile" <<'PYFP' 2>/dev/null || true
import hashlib, sys
try:
    from cryptography.hazmat.primitives import serialization
except ImportError:
    sys.exit(0)
try:
    data = open(sys.argv[1], "rb").read()
    key = serialization.load_pem_private_key(data, password=None)
    der = key.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
except Exception:
    sys.exit(0)
digest = hashlib.md5(der).hexdigest()
print(":".join(digest[i:i + 2] for i in range(0, len(digest), 2)))
PYFP
}

# Is the file even parseable, and does it hold a usable profile?
config_is_sane() {
    local file="$OCI_DIR/config"
    [ -f "$file" ] || return 1
    python3 - "$file" <<'PYSANE' >/dev/null 2>&1
import configparser, sys
parser = configparser.ConfigParser()
parser.read(sys.argv[1])
# A usable config has a DEFAULT profile carrying at least these.
d = parser.defaults()
sys.exit(0 if all(d.get(k) for k in ("user", "tenancy", "fingerprint")) else 1)
PYSANE
}

# ---------------------------------------------------------------------
# --repair-config
# ---------------------------------------------------------------------
#
# Pasting the Console's config snippet into a terminal often loses the
# newlines, leaving every key on one line. The SDK then reads nothing at
# all. This rewrites the file with one key per line, strips quotes and
# trailing comments from key_file, and makes the path absolute.

if [ "$REPAIR_ONLY" = 1 ]; then
    CFG="$OCI_DIR/config"
    [ -f "$CFG" ] || die "no $CFG to repair"

    step "repairing $CFG"
    cp -p "$CFG" "$CFG.broken-$(date +%Y%m%d-%H%M%S)"
    info "original saved alongside it"

    python3 - "$CFG" "$HOME" <<'PYREPAIR' || die "could not repair the config"
import re, sys, pathlib

path = pathlib.Path(sys.argv[1])
home = sys.argv[2]
raw = path.read_text(encoding="utf-8", errors="replace")

# Split on the key names themselves, so a file with no newlines is
# recovered rather than rejected.
KEYS = ("user", "fingerprint", "tenancy", "region", "key_file",
        "pass_phrase", "security_token_file", "delegation_token_file")

text = re.sub(r"\[([A-Za-z0-9_-]+)\]", r"\n[\1]\n", raw)
for key in KEYS:
    text = re.sub(rf"(?<![A-Za-z_]){key}\s*=", f"\n{key}=", text)

profile, found = "DEFAULT", {}
for line in text.splitlines():
    line = line.strip()
    if not line or line.startswith(("#", ";")):
        continue
    m = re.fullmatch(r"\[([A-Za-z0-9_-]+)\]", line)
    if m:
        profile = m.group(1)
        continue
    if "=" not in line:
        continue
    key, _, value = line.partition("=")
    key = key.strip().lower()
    if key not in KEYS:
        continue
    # Drop a trailing comment, then surrounding quotes.
    value = re.split(r"\s+[#;]", value.strip(), maxsplit=1)[0].strip()
    value = value.strip().strip('"').strip("'").strip()
    if key == "key_file":
        if value.startswith("~"):
            value = home + value[1:]
        elif value.startswith("$HOME"):
            value = home + value[len("$HOME"):]
        if not value.startswith("/"):
            value = f"{home}/.oci/{value.lstrip('./')}"
    if value:
        found[key] = value

missing = [k for k in ("user", "fingerprint", "tenancy", "region") if k not in found]
if missing:
    print(f"  could not recover: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)

found.setdefault("key_file", f"{home}/.oci/oci_api_key.pem")

order = ["user", "fingerprint", "tenancy", "region", "key_file", "pass_phrase"]
out = ["[DEFAULT]"]
out += [f"{k}={found[k]}" for k in order if k in found]
path.write_text("\n".join(out) + "\n", encoding="utf-8")
print("  rewrote with one key per line")
PYREPAIR

    chmod 600 "$CFG"

    printf '\n' >&2
    if config_is_sane; then
        step "config now parses"
    else
        die "still unreadable — inspect $CFG by hand"
    fi

    kf=$(config_value key_file)
    if [ -n "$kf" ] && [ ! -f "$kf" ]; then
        warn "key_file points at $kf, which does not exist"
    fi

    printf '\n  %sResult:%s\n\n' "$B" "$N"
    sed 's/^/    /' "$CFG" >&2
    printf '\n  Verify with:  bash %s --check\n\n' "$(basename "$0")" >&2
    exit 0
fi

# ---------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------

if [ "$CHECK_ONLY" = 1 ]; then
    printf '\n  %sOCI CLI status%s\n\n' "$B" "$N"
    fail=0

    if command -v oci >/dev/null 2>&1; then
        printf '  %s✓%s oci installed (%s)\n' "$G" "$N" "$(oci --version 2>&1 | head -1)"
    else
        printf '  %s✗%s oci not on PATH\n' "$R" "$N"; fail=1
    fi

    if python -c 'import crc32c' >/dev/null 2>&1; then
        printf '  %s✓%s crc32c importable\n' "$G" "$N"
    else
        printf '  %s✗%s crc32c missing (oci will not start)\n' "$R" "$N"; fail=1
    fi

    if [ -f "$OCI_DIR/config" ]; then
        printf '  %s✓%s %s exists\n' "$G" "$N" "$OCI_DIR/config"

        lines=$(wc -l < "$OCI_DIR/config" | tr -d ' ')
        if [ "$lines" -lt 2 ] 2>/dev/null; then
            printf '  %s✗%s config is a single line — every key ran together\n' "$R" "$N"
            printf '      A config pasted without newlines is unreadable to the SDK.\n'
            printf '      Repair it with:  bash %s --repair-config\n' "$(basename "$0")"
            fail=1
        elif config_is_sane; then
            printf '  %s✓%s config parses, DEFAULT profile present\n' "$G" "$N"
        else
            printf '  %s✗%s config does not parse into a usable profile\n' "$R" "$N"
            printf '      Repair it with:  bash %s --repair-config\n' "$(basename "$0")"
            fail=1
        fi
        mode=$(stat -c '%a' "$OCI_DIR/config" 2>/dev/null || echo '?')
        if [ "$mode" = "600" ]; then
            printf '  %s✓%s config permission 600\n' "$G" "$N"
        else
            printf '  %s✗%s config permission %s (should be 600)\n' "$Y" "$N" "$mode"
        fi
        kf=$(config_value key_file)
        if [ -z "$kf" ]; then
            printf '  %s✗%s no usable key_file in config\n' "$R" "$N"; fail=1
        else
            case "$kf" in
                *'"'*|*"'"*)
                    printf '  %s✗%s key_file is quoted; the SDK reads the quotes literally\n' "$R" "$N"
                    printf '      found: %s\n' "$kf"; fail=1 ;;
                *"#"*)
                    printf '  %s✗%s key_file has a trailing comment on the same line\n' "$R" "$N"
                    printf '      found: %s\n' "$kf"; fail=1 ;;
                "~"*|'$HOME'*)
                    printf '  %s✗%s key_file starts with ~ or $HOME; the SDK does not expand it\n' "$R" "$N"
                    printf '      found: %s\n' "$kf"; fail=1 ;;
                /*) printf '  %s✓%s key_file is absolute\n' "$G" "$N" ;;
                *)  printf '  %s✗%s key_file must be an absolute path: %s\n' "$R" "$N" "$kf"; fail=1 ;;
            esac
        fi
        if [ -n "$kf" ] && [ -f "$kf" ]; then
            printf '  %s✓%s private key present\n' "$G" "$N"
            kmode=$(stat -c '%a' "$kf" 2>/dev/null || echo '?')
            if [ "$kmode" = "600" ]; then
                printf '  %s✓%s private key permission 600\n' "$G" "$N"
            else
                printf '  %s!%s private key permission %s (should be 600)\n' "$Y" "$N" "$kmode"
            fi

            actual=$(key_fingerprint "$kf")
            declared=$(config_value fingerprint)
            if [ -z "$actual" ]; then
                printf '  %s✗%s cannot derive a fingerprint from the key\n' "$R" "$N"
                printf '      It may be encrypted (needs a pass_phrase), not RSA,\n'
                printf '      or in a format OpenSSL here cannot read.\n'
                fail=1
            elif [ "$actual" = "$declared" ]; then
                printf '  %s✓%s fingerprint matches the key\n' "$G" "$N"
            else
                printf '  %s✗%s fingerprint mismatch\n' "$R" "$N"
                printf '      config: %s\n      key:    %s\n' "$declared" "$actual"; fail=1
            fi
        elif [ -n "$kf" ]; then
            printf '  %s✗%s private key not found at %s\n' "$R" "$N" "$kf"; fail=1
        fi
    else
        printf '  %s✗%s no %s\n' "$R" "$N" "$OCI_DIR/config"; fail=1
    fi

    printf '\n'
    if [ "$fail" = 0 ]; then
        step "testing against the API"
        if oci iam region list --output table >/dev/null 2>&1; then
            printf '  %s✓ authentication works%s\n\n' "$G" "$N"
        else
            printf '  %s✗ API call failed — run: oci iam region list%s\n\n' "$R" "$N"
            exit 1
        fi
    else
        printf '  See docs/09-oci-cli-termux.md\n\n'
        exit 1
    fi
    exit 0
fi

# ---------------------------------------------------------------------
# environment
# ---------------------------------------------------------------------

if [ -z "${PREFIX:-}" ] || ! case "${PREFIX:-}" in *com.termux*) true;; *) false;; esac; then
    warn "this does not look like Termux — the OCI CLI installs normally elsewhere"
fi

ARCH="$(uname -m)"

cat >&2 <<PLAN

  ${B}OCI CLI for Termux${N}

  Architecture : $ARCH

  Oracle's install.sh does not support Termux: it probes for
  dnf/yum/apt-get, finds none, and exits. This does the same job with
  pkg and pip.

  Will install:
    1. python, pip, openssl, libffi, rust, binutils, clang
    2. python-cryptography  ${D}(from Termux, avoids a 40-minute build)${N}
    3. crc32c               ${D}(with the CPU flags clang needs)${N}
    4. oci-cli

PLAN

if [ "$ASSUME_YES" != 1 ]; then
    if [ -t 0 ]; then
        printf '  Continue? [Y/n] ' >&2
        read -r reply || reply=""
        case "$reply" in [Nn]*) echo "  aborted" >&2; exit 0 ;; esac
    else
        die "not a terminal — pass --yes"
    fi
fi

# ---------------------------------------------------------------------
# 1. system packages
# ---------------------------------------------------------------------

step "installing system packages"
if command -v pkg >/dev/null 2>&1; then
    pkg install -y python python-pip openssl libffi rust binutils clang \
        || die "pkg install failed"
else
    warn "no pkg command; assuming the toolchain is already present"
fi

# ---------------------------------------------------------------------
# 2. cryptography from Termux, not pip
# ---------------------------------------------------------------------
#
# Building cryptography from source needs Rust and takes 20-40 minutes on
# a phone, often dying out of memory. Termux ships a prebuilt one.

if python -c 'import cryptography' >/dev/null 2>&1; then
    info "cryptography already present ($(python -c 'import cryptography; print(cryptography.__version__)'))"
else
    step "installing python-cryptography from the Termux repository"
    pkg install -y python-cryptography \
        || warn "not available; pip will try to build it (slow)"
fi

# ---------------------------------------------------------------------
# 3. crc32c — the part that actually breaks
# ---------------------------------------------------------------------
#
# crc32c's ARM64 source enables CPU features with:
#
#     #pragma GCC target ("+crc+crypto")
#
# That is GCC syntax. Termux uses clang, which ignores the pragma
# ("unknown pragma ignored") and then refuses the intrinsics behind it:
#
#     __crc32cd()  needs feature 'crc'
#     vmull_p64()  needs feature 'aes'   (part of 'crypto')
#
# Passing both features as a compiler flag is what makes it build.
# Supplying only +crc gets you from 20 errors down to 3 — a trap, because
# it looks like progress.
#
# crc32c is not optional: oci/__init__.py imports it transitively via
# pagination -> object_storage, so the CLI will not even start without it.

CRC_FLAGS="-march=armv8-a+crc+crypto"
case "$ARCH" in
    aarch64|arm64) ;;
    armv7l|armv8l) CRC_FLAGS="-march=armv7-a+crc" ;;
    x86_64)        CRC_FLAGS="-msse4.2" ;;
    *)             CRC_FLAGS="" ; warn "unknown arch $ARCH; building crc32c without CPU flags" ;;
esac

if python -c 'import crc32c' >/dev/null 2>&1; then
    info "crc32c already importable"
else
    step "building crc32c ($CRC_FLAGS)"
    # A stale failed build is cached; drop it or pip reuses the failure.
    pip cache remove crc32c >/dev/null 2>&1 || true

    if CFLAGS="$CRC_FLAGS" pip install crc32c; then
        info "crc32c built"
    else
        warn "compilation failed — falling back to a pure-Python implementation"
        SITE="$(python -c 'import site; print(site.getsitepackages()[0])')"
        cat > "$SITE/crc32c.py" <<'PYSHIM'
"""Pure-Python CRC32C (Castagnoli), used when the C extension will not build.

Slower than the compiled version, but correct: verified against the
reference vectors, e.g. crc32c(b"123456789") == 0xe3069283.
"""

_POLY = 0x82F63B78
_TABLE = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ (_POLY if _c & 1 else 0)
    _TABLE.append(_c)


def crc32c(data, value=0):
    crc = value ^ 0xFFFFFFFF
    for byte in data:
        crc = _TABLE[(crc ^ byte) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF


def crc32(data, value=0):
    return crc32c(data, value)


hardware_based = False
PYSHIM
        python -c 'import crc32c; assert crc32c.crc32c(b"123456789") == 0xe3069283' \
            || die "the fallback shim is broken; please report this"
        info "pure-Python fallback installed and verified"
    fi
fi

python -c 'import crc32c; print("crc32c ok:", crc32c.crc32c(b"test"))' >&2

# ---------------------------------------------------------------------
# 4. oci-cli
# ---------------------------------------------------------------------

if command -v oci >/dev/null 2>&1; then
    info "oci-cli already installed ($(oci --version 2>&1 | head -1))"
else
    step "installing oci-cli (this downloads about 60 MB)"
    pip install oci-cli || die "pip install oci-cli failed"
fi

command -v oci >/dev/null 2>&1 || export PATH="$HOME/.local/bin:$PATH"
command -v oci >/dev/null 2>&1 || die "oci is not on PATH after install"

# ---------------------------------------------------------------------
# 5. tidy credentials if they are already here
# ---------------------------------------------------------------------

if [ -d "$OCI_DIR" ]; then
    step "checking existing credentials"
    chmod 700 "$OCI_DIR" 2>/dev/null || true
    chmod 600 "$OCI_DIR"/config "$OCI_DIR"/*.pem 2>/dev/null || true

    if [ -f "$OCI_DIR/config" ]; then
        kf=$(config_value key_file)
        # A leading ~ or $HOME is not expanded by the Python SDK, so a
        # config that looks fine to a human still fails at runtime.
        tilde='~'
        case "$kf" in
            "") warn "config has no key_file line" ;;
            /*) ;;
            "$tilde"/*|'$HOME'/*)
                abs="$HOME/${kf#*/}"
                warn "key_file is not absolute; rewriting to $abs"
                cp -p "$OCI_DIR/config" "$OCI_DIR/config.bak"
                sed -i "s|^[[:space:]]*key_file[[:space:]]*=.*|key_file=$abs|" "$OCI_DIR/config"
                ;;
            *) warn "key_file looks wrong: $kf" ;;
        esac
    fi
else
    info "no ~/.oci yet — run 'oci setup config' or copy your files there"
fi

cat >&2 <<DONE

  ${G}OCI CLI ready.${N}  $(oci --version 2>&1 | head -1)

  Verify everything:

    bash $(basename "$0") --check

  Or test directly:

    oci iam region list --output table

DONE
