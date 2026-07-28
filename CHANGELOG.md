# Changelog

## [1.3.2] — 2026-07-28

### Fixed

- **Unrecognised launch errors printed the least useful part of the
  message.** The loop showed the last three lines of the CLI's output,
  but OCI appends a timestamp and a generic troubleshooting URL, so the
  `code`, `status` and `message` fields that name the actual problem
  scrolled out of view. Errors are now parsed as JSON and those three
  fields printed.
- HTTP 429 / `TooManyRequests` is now recognised as rate limiting rather
  than an unknown error, and backs off for 60 seconds instead of
  hammering the API on the next tick.

## [1.3.1] — 2026-07-28

### Fixed

- Scripts lost their executable bit in an earlier commit. Restored, so
  `./scripts/foo.sh` works again rather than only `bash scripts/foo.sh`.

### Changed

- `oci-grab-arm.sh` now recognises single-AD regions — Singapore has
  exactly one — where rotating availability domains does nothing. It
  says so and suggests the only lever that actually helps: asking for a
  smaller shape. A 4-OCPU request needs four free cores on one host,
  which is far rarer than one.
- Prints a progress summary every twelfth pass so a long hunt does not
  look like it has stalled.

## [1.3.0] — 2026-07-28

### Added

- **`scripts/oci-grab-arm.sh`** — retries an Always Free Ampere launch
  until Oracle has capacity. `Out of capacity for shape
  VM.Standard.A1.Flex` is not a misconfiguration; the free ARM pool in
  popular regions is simply contended, and the fix is to keep asking.

  Cycles through every availability domain, tells quota and auth
  failures apart from capacity failures and stops immediately on those,
  and fires a Termux notification plus vibration when it wins.

## [1.2.1] — 2026-07-28

### Fixed

- **`--setup-key` implied Cloud Shell was a valid place to authorise the
  key.** It said "paste this into the VM (Cloud Shell works)", which
  reads as though Cloud Shell *is* the VM. It is a separate Oracle
  machine, so a key added there grants nothing on your instance —
  and the resulting `Permission denied (publickey)` gives no clue why.
  The instructions now show the difference in prompts and explain how to
  reach the VM the first time.
- `--connect` warns when given an RFC 1918 address (`10.x`,
  `172.16-31.x`, `192.168.x`), which is only reachable from inside the
  VCN.
- A failed connection now lists the likely causes in order, with the
  `ssh -v` command to confirm.

## [1.2.0] — 2026-07-28

### Added

- **`scripts/oci-vm-connect.sh`** — lists your OCI instances with their
  public and private IPs via the CLI, generates or reuses an SSH key,
  prints the exact line to authorise on the VM, and connects with
  keepalives suited to a mobile connection.
- **`docs/10-ssh-into-oci-vm.md`** — getting a real terminal instead of
  the browser console, including how to copy logs out (clipboard, files,
  `scp`) and how to survive a dropped signal with `tmux`.

### Note

The chapter opens by separating the two credentials people routinely
confuse: the **API signing key** (`~/.oci/oci_api_key.pem`, for the CLI)
and the **SSH key** (`~/.ssh/id_ed25519`, for shell access). They are
not interchangeable, and reusing one for both is a bad idea even where
the maths allows it.

## [1.1.3] — 2026-07-27

### Fixed

- **False "cannot read the private key" in `--check`.** The fingerprint
  was derived by text-parsing `openssl md5 -c` output, which some builds
  print as `MD5(stdin)=aa:bb` with no space — field-splitting then
  yielded an empty string and the key was declared unreadable even
  though `oci` worked perfectly.
- **A worse variant of the same bug:** for an *encrypted* private key,
  `openssl rsa` writes nothing and the pipeline hashed empty input,
  producing `d41d8cd9...` — a plausible-looking fingerprint that is
  simply wrong. An encrypted key is now reported as such.

Fingerprints are now computed with Python's `cryptography` (already
present, since `oci-cli` depends on it) instead of scraping command
output.

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

[1.3.2]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.3.2
[1.3.1]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.3.1
[1.3.0]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.3.0
[1.2.1]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.2.1
[1.2.0]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.2.0
[1.1.3]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.1.3
[1.1.2]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.1.2
[1.1.1]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.1.1
[1.1.0]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.1.0
[1.0.0]: https://github.com/ivansslo/termuxrd-cloud/releases/tag/v1.0.0
