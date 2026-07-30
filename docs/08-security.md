# 8. Security

Short chapter, but the one that matters most.

---

## What this setup gets right

- **No inbound ports.** Tailscale is outbound-only; nothing listens on
  the VM's public interface.
- **No exposed Docker socket.** The daemon stays on its Unix socket and
  is reached over SSH.
- **WireGuard encryption** end to end, with authentication handled by
  your tailnet identity.
- **Small blast radius** - a lost phone is removed by revoking one
  device in the Tailscale admin console.

## What it does not protect against

- **Membership of the `docker` group is root on the VM.** A container
  can mount the host filesystem. Treat it as `sudo`.
- **Anything on your tailnet can reach the VM** unless you write ACLs.
  Default tailnet policy is allow-all between your own devices.
- **A rootless container on the phone is not a security boundary.** PRoot
  emulates uid 0 by rewriting syscalls; it does not confine hostile code.
  Do not run untrusted code in it and expect containment.

---

## Never commit credentials

Nothing in this repository is real. Keep it that way.

**Do not commit:** private keys (`.pem`, `id_ed25519`), Tailscale auth
keys (`tskey-...`), cloud API keys, `~/.oci/config`, `.env` with real
values, `~/.docker/config.json`.

**Safe to share:** Tailscale IPs (`100.x.y.z` is private space),
MagicDNS names, public keys, region names.

**Ambiguous - treat as sensitive:** OCIDs and key fingerprints. They
cannot authenticate on their own, but they identify your account and
help an attacker target you.

Use env vars, and read them at the point of use:

```bash
# ~/.oci_env, chmod 600, never committed
export OCI_USER="ocid1.user.oc1..aaaa..."
export OCI_TENANCY="ocid1.tenancy.oc1..aaaa..."
export OCI_FINGERPRINT="aa:bb:cc:..."
export OCI_REGION="ap-singapore-1"
```

```bash
source ~/.oci_env
```

A `.gitignore` covering the usual mistakes is included in this repo.

---

## If you have already leaked something

Rotate first, investigate afterwards. Rotation is cheap; a compromised
tenancy is not.

**OCI API key**

1. Console → Profile → **My profile** → API keys → delete the old
   fingerprint.
2. **Add API key**, download the new private key.
3. Update `~/.oci/config`, `chmod 600`.
4. Audit → **Search** for activity under the old key.

**Tailscale auth key** - Admin console → **Settings → Keys** → revoke.
Node keys are separate; revoke a *machine* under **Machines → ⋯ →
Remove**.

**SSH key** - remove the line from `~/.ssh/authorized_keys` on every
host, then generate a new pair.

**AWS access key** - IAM → Users → Security credentials → deactivate,
then delete. Prefer instance roles so there is no key at all.

### If a secret reached a git commit

Deleting the file in a later commit does **not** remove it - the blob
stays in history and on any clone or fork.

```bash
pip install git-filter-repo
git filter-repo --path path/to/secret --invert-paths
git push --force
```

Rotate the credential anyway. Assume anything pushed publicly, even
briefly, was scraped.

---

## Hardening worth doing

### Disable public SSH once Tailscale works

The single highest-value change. Confirm tailnet SSH works **first**, in
a session you keep open.

OCI: remove the port 22 ingress rule from the Security List.
AWS: remove the port 22 inbound rule from the Security Group.

Now the VM has no public attack surface at all. Keep the cloud console's
browser SSH as your way back in.

### Tailscale ACLs

Default policy lets every device reach every other. Narrow it -
Admin console → **Access controls**:

```jsonc
{
  "acls": [
    // phone may reach the server; not the reverse
    { "action": "accept", "src": ["tag:phone"], "dst": ["tag:server:22,8080"] }
  ],
  "tagOwners": {
    "tag:phone":  ["autogroup:admin"],
    "tag:server": ["autogroup:admin"]
  }
}
```

### Unattended security updates

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

### Do not run containers as root

```yaml
services:
  app:
    image: myapp
    user: "1000:1000"
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
```

### Compose secrets, not environment variables

Values in `environment:` are visible in `docker inspect` and in the
process list. Use file-based secrets - as the Nextcloud example in
[chapter 5](05-workloads.md#53-nextcloud-with-compose) does.

---

## Losing your phone

1. Tailscale admin console → **Machines** → remove the phone.
2. Remove its public key from `~/.ssh/authorized_keys` on the VM.
3. If you used Tailscale SSH, step 1 is sufficient.

Access is revoked immediately; the device cannot re-authenticate.

---

## A realistic threat model

For a personal server this setup is solid: no public ports, encrypted
transport, revocable per-device access. The likely failure modes are
mundane - a leaked key in a screenshot, an expired node key, a container
running as root that did not need to be.

It is not a substitute for real isolation if you run untrusted
workloads. For that you want separate VMs, or at minimum rootless Docker
with user namespaces on the server.
