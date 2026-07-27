# Changelog

## [1.1.0] — 2026-07-27

### Added

- **`scripts/termux-oci-cli.sh`** — installs the OCI CLI on Termux,
  which Oracle's own `install.sh` cannot do: it probes for
  dnf/yum/apt-get, finds none, and exits.
- **`docs/09-oci-cli-termux.md`** — the full explanation, plus how to
  use an API key that is already on the phone, and which container the
  CLI should live in.
- `--check` mode that verifies the install end to end: `oci` on PATH,
  `crc32c` importable, config permissions, `key_file` absolute, and the
  fingerprint actually matching the private key.

### The `crc32c` fix

`crc32c` fails to compile on Termux. Its ARM64 source enables CPU
features with `#pragma GCC target ("+crc+crypto")`, which is GCC syntax;
clang ignores it and then rejects the intrinsics behind it.

Passing only `+crc` takes you from 20 errors to 3 — which looks like
progress but still fails, because `vmull_p64()` needs `aes` as well.
Both features are required:

```bash
CFLAGS="-march=armv8-a+crc+crypto" pip install crc32c
```

`crc32c` cannot be skipped: `oci/__init__.py` imports it transitively
through `pagination → object_storage`, so `--no-deps` produces a CLI
that will not start.

The script falls back to a pure-Python CRC32C if compilation still
fails. CI verifies that fallback against the reference vectors
(`crc32c(b"123456789") == 0xe3069283`) and guards against anyone
dropping `+crypto` from the flags.

Reported and confirmed working on aarch64 Android by @ivansslo.

## [1.0.0] — 2026-07-27

Initial release: eight chapters and three scripts for running Docker on
an Oracle Cloud or AWS VM from Android over Tailscale.

[1.1.0]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.1.0
[1.0.0]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.0.0
