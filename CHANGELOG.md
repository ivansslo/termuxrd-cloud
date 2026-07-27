# Changelog

## [1.1.2] — 2026-07-27

### Added

- **`--repair-config`** — rebuilds a mangled `~/.oci/config`. Pasting
  the Console's snippet into a terminal frequently loses the newlines,
  leaving every key on one line; the SDK then reads *nothing*, and
  `oci` fails with no useful message. The repair splits on key names,
  strips quotes and trailing comments, expands `~`/`$HOME` in
  `key_file`, and keeps a timestamped copy of the original.

### Fixed

- `--check` now validates that the config actually **parses** with
  Python's `configparser` — the same reader the SDK uses — instead of
  matching lines with `sed`. A single-line config previously looked
  half-valid: the permission check passed, then `key_file` was reported
  missing, which pointed at the wrong problem.
- `key_file` problems are now named precisely: quoted value, trailing
  comment, or a leading `~`/`$HOME`. Each is read literally by the SDK
  and each was previously lumped together as "not absolute".

## [1.1.1] — 2026-07-27

### Fixed

- **`--check` exited silently partway through the report.** Under
  `set -euo pipefail`, a `grep` that finds nothing returns 1 and killed
  the script — so a config with no `key_file` line stopped the output
  after "config permission" with no explanation and exit code 1.
  Lookups now go through a helper that returns an empty string instead
  of aborting, and the missing key is reported as a normal finding.
- `--check` also reports private key permissions, and distinguishes an
  unreadable or non-RSA key from a fingerprint mismatch.

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

[1.1.2]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.1.2
[1.1.1]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.1.1
[1.1.0]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.1.0
[1.0.0]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.0.0
