# 9. OCI CLI di Termux

Oracle's official installer cannot run on Termux. This chapter explains
why, gives the working method, and covers using an existing API key.

```bash
bash scripts/termux-oci-cli.sh
bash scripts/termux-oci-cli.sh --check
```

---

## 9.1 Why the official installer fails

```bash
# This does not work on Termux:
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

Its OS detection is:

```
dnf?     → dnf install python3
yum?     → yum install gcc libffi-devel …
apt-get? → apt-get install python3-pip
else     → ERROR: Could not install Python 3 based on operating system
```

Termux has `pkg`, none of those three. The script also calls `sudo`,
reads `/etc/os-release`, and installs into `/usr/local/bin` - none of
which exist or are writable on Android.

---

## 9.2 The real obstacle: `crc32c`

Even once Python is sorted, one dependency refuses to build.

`crc32c` enables ARM CPU features like this:

```c
#if defined(__GNUC__)
# pragma GCC target ("+crc+crypto")
#endif
```

That is **GCC** syntax. Termux uses **clang**, which reports
`unknown pragma ignored` and then rejects the intrinsics that pragma was
supposed to enable:

| Function | Needs feature |
|---|---|
| `__crc32cd()` | `crc` |
| `vmull_p64()` | `aes` - part of `crypto` |

### The trap

Supplying only half the features looks like progress but is not:

```bash
CFLAGS="-march=armv8-a+crc" pip install crc32c     # 20 errors → 3 errors
```

Fewer errors, still broken. You need both:

```bash
CFLAGS="-march=armv8-a+crc+crypto" pip install crc32c    # ✅
```

### `crc32c` is not optional

You cannot skip it with `--no-deps`. `oci/__init__.py` imports it
transitively at load time:

```
oci/__init__.py → pagination → object_storage → import crc32c
```

So `oci --version` fails with `ModuleNotFoundError: No module named
'crc32c'` even if you never touch Object Storage.

Two other things that do **not** help:

- `--no-build-isolation` → `Cannot import 'setuptools.build_meta'`,
  because Termux's Python 3.14 ships no setuptools.
- `CRC32C_SW_MODE=force` → read at *runtime*, not compile time.

---

## 9.3 Working installation

```bash
pkg install -y python python-pip openssl libffi rust binutils clang
pkg install -y python-cryptography        # prebuilt; avoids a 40-min Rust build

CFLAGS="-march=armv8-a+crc+crypto" pip install crc32c
python -c "import crc32c; print('ok', crc32c.crc32c(b'test'))"   # → ok 2258662080

pip install oci-cli
oci --version
```

Or just run the script, which also handles 32-bit ARM and x86 Android,
and falls back to a pure-Python `crc32c` if compilation still fails:

```bash
bash scripts/termux-oci-cli.sh
```

---

## 9.4 Using an API key you already have

If `~/.oci/` already contains your key, you only need to check three
things.

```bash
ls ~/.oci/
# config  oci_api_key.pem  oci_api_key_public.pem
```

### The config must have one key per line

Pasting the Console snippet into a terminal often loses the newlines,
producing a file like this:

```
[DEFAULT] user=ocid1... fingerprint=a1:3a... region=ap-singapore-1 key_file="~/.oci/oci_api_key.pem"
```

The SDK reads **nothing** from that - not a partial config, nothing at
all. Check quickly:

```bash
wc -l ~/.oci/config      # fewer than 2 lines means it is broken
```

Repair it:

```bash
bash scripts/termux-oci-cli.sh --repair-config
```

The original is kept as `config.broken-<timestamp>`.

A correct config looks like:

```ini
[DEFAULT]
user=ocid1.user.oc1..aaaa
fingerprint=a1:3a:75:...
tenancy=ocid1.tenancy.oc1..aaaa
region=ap-singapore-1
key_file=/data/data/com.termux/files/home/.oci/oci_api_key.pem
```

No quotes around `key_file`, no trailing `# comment`, no `~`.

### Permissions

```bash
chmod 700 ~/.oci
chmod 600 ~/.oci/config ~/.oci/*.pem
```

### `key_file` must be an absolute path

This is the most common failure on Termux. `~` is **not** expanded by
the Python SDK.

```bash
grep key_file ~/.oci/config
```

Must read:

```ini
key_file=/data/data/com.termux/files/home/.oci/oci_api_key.pem
```

Not `~/.oci/...` and not `$HOME/.oci/...`. Fix it with:

```bash
sed -i "s|^key_file=.*|key_file=$HOME/.oci/oci_api_key.pem|" ~/.oci/config
```

### Fingerprint must match the key

```bash
openssl rsa -pubout -outform DER -in ~/.oci/oci_api_key.pem 2>/dev/null \
  | openssl md5 -c | awk '{print $2}'
grep fingerprint ~/.oci/config
```

Identical? Good. Different means the config points at a key that is not
the one registered in the Console.

### Test

```bash
oci iam region list --output table
```

All three checks are automated:

```bash
bash scripts/termux-oci-cli.sh --check
```

---

## 9.5 Where should the CLI live?

You have Termux, and containers. Short answer: **install it in Termux**,
alongside your key.

| | Termux | rootd container |
|---|---|---|
| Key already here | ✅ | must be copied |
| Copies of the private key | 1 | 2 |
| `rootd backup` includes the key | no | **yes** |
| Build difficulty | needs the CFLAGS above | easier (gcc) |

Two copies of a private key means rotating it twice, and it means your
box archives contain credentials. Prefer one copy.

Your existing containers are for other jobs:

| Container | Purpose |
|---|---|
| `alpine` | general scratch space |
| `docker` | Docker client → remote daemon (chapters 3-4) |

Do not put the OCI CLI in the `docker` container. Keeping one tool per
container means you can delete or rebuild one without disturbing the
other.

### If you do want it in a container

Use a dedicated one, never the `docker` box:

```bash
rootd install alpine --name ocicli
rootd sh ocicli -- apk add --no-cache python3 py3-pip gcc musl-dev python3-dev linux-headers
rootd sh ocicli -- pip install --break-system-packages oci-cli
```

Alpine uses gcc, which understands `#pragma GCC target`, so the crc32c
problem does not arise.

Copy credentials in and fix the path:

```bash
BOX=$(rootd info ocicli | awk '/rootfs/{print $2}')
mkdir -p "$BOX/root/.oci"
cp ~/.oci/config ~/.oci/*.pem "$BOX/root/.oci/"
chmod 600 "$BOX/root/.oci/"*
sed -i 's|^key_file=.*|key_file=/root/.oci/oci_api_key.pem|' "$BOX/root/.oci/config"
rootd sh ocicli -- oci iam region list --output table
```

> ⚠️ Your private key now exists in two places. Rotating it means
> updating both, and `rootd backup ocicli` will place a copy inside the
> archive - store that archive as carefully as the key itself.

---

## 9.6 Useful commands

```bash
# who am I
oci iam region list --output table
oci iam compartment list --output table

# compute instances
oci compute instance list --compartment-id "$COMP" --output table

# API gateways
oci api-gateway gateway list --compartment-id "$COMP" --output table
oci api-gateway api get --api-id ocid1.apigatewayapi.oc1...

# a specific instance's public IP
oci compute instance list-vnics --instance-id "$INSTANCE" \
  --query 'data[0]."public-ip"' --raw-output
```

Save your compartment OCID so you stop retyping it:

```bash
echo "export COMP=$(grep '^tenancy' ~/.oci/config | cut -d= -f2)" >> ~/.bashrc
source ~/.bashrc
```

---

## 9.7 Security

A private key on your phone means anyone holding your unlocked phone
holds your OCI account.

Consider a **separate OCI user for the phone**, with a read-only policy:

```
Allow group phone-readonly to inspect all-resources in tenancy
```

Then losing the phone costs you a read-only key, revoked from the
Console in seconds, without touching the credentials you use elsewhere.

Never commit `~/.oci/` to a repository. This project's `.gitignore`
already excludes it.

---

## 9.8 Or skip installing entirely

For occasional checks, **Cloud Shell** is faster than any of this: open
cloud.oracle.com, click the `>_` icon. The CLI is installed and already
authenticated - no key on your phone at all. It works from a phone
browser.

```bash
oci api-gateway gateway list \
  --compartment-id "$(oci iam compartment list --query 'data[0].id' --raw-output)" \
  --output table
```
