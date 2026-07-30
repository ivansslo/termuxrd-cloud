# 1. Tailscale on the VM

**Goal:** the VM joins your tailnet and gets a `100.x.y.z` address your
phone can reach from anywhere, without opening a single firewall port.

Time: about 10 minutes.

---

## 1.1 Connect to the VM

However you normally do it - the cloud console's browser SSH, or:

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<public-ip>
```

Default login users:

| Image | User |
|---|---|
| Ubuntu (OCI and AWS) | `ubuntu` |
| Oracle Linux | `opc` |
| Amazon Linux | `ec2-user` |
| Debian | `admin` or `debian` |

Confirm where you are - this decides which notes apply to you later:

```bash
uname -r
```

A `-oracle` or `-generic` suffix means Oracle Cloud. `-aws` means EC2.
`6.14.0-1018-aws`, for instance, is an EC2 instance.

---

## 1.2 Install Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

The script detects your distribution and adds Tailscale's package
repository. To inspect it first - reasonable for anything piped to a
shell:

```bash
curl -fsSL https://tailscale.com/install.sh -o ts.sh
less ts.sh
sh ts.sh
```

Verify:

```bash
tailscale version
```

---

## 1.3 Bring it up

```bash
sudo tailscale up --ssh --hostname=myserver
```

A login URL is printed. Open it in any browser, sign in, and approve the
machine. The terminal continues once it is authorised.

What the flags do:

- `--ssh` enables **Tailscale SSH**: the daemon itself terminates SSH
  connections from your tailnet, with access decided by your tailnet
  policy rather than by `authorized_keys`. It is optional but removes a
  lot of key management.
- `--hostname=` sets the tailnet name. Use something you will recognise;
  it becomes part of your MagicDNS name.

### Unattended setup

For scripts or images, use a pre-authentication key from
**Settings → Keys** in the admin console:

```bash
sudo tailscale up --ssh --hostname=myserver --authkey="tskey-auth-..."
```

Treat that key like a password. Prefer an *ephemeral* key for anything
disposable, so the node removes itself when it goes offline.

---

## 1.4 Note the address

```bash
tailscale ip -4
```

Something like `100.101.102.103`. **Write it down** - you need it on the
phone.

Confirm the daemon is healthy:

```bash
tailscale status
```

You should see your VM and any other devices already on the tailnet.

---

## 1.5 Stop the key from expiring

By default a node key expires after 180 days and the machine silently
drops off your tailnet. For a server you rely on, disable that:

**Admin console → Machines → your machine → ⋯ → Disable key expiry**

The machine list will then show *Expiry disabled* or *No expiry*. Skip
this and your setup will mysteriously stop working in six months, at
which point you will have forgotten why.

---

## 1.6 Survive reboots

The installer usually enables the service already. Make sure:

```bash
sudo systemctl enable --now tailscaled
systemctl is-enabled tailscaled     # -> enabled
```

Test properly:

```bash
sudo reboot
# wait ~30 seconds, reconnect
tailscale status
```

---

## 1.7 What you did *not* have to do

No inbound firewall rules. Tailscale is outbound-only: the daemon dials
out to the coordination server, then negotiates a direct WireGuard
tunnel with your other devices, falling back to an encrypted DERP relay
when a direct path is impossible.

Concretely, you skipped:

- **Oracle Cloud** - Security List ingress rules, *and* the host
  `iptables` REJECT rule that silently blocks non-SSH ports on OCI's
  Ubuntu images. That rule catches out an enormous number of people.
- **AWS** - Security Group inbound rules.

Outbound is all that is needed, and both clouds allow it by default:

| Port | Purpose |
|---|---|
| 41641/udp | direct WireGuard (best case) |
| 3478/udp | STUN, for NAT traversal |
| 443/tcp | control plane and DERP relay fallback |

If outbound UDP is blocked, Tailscale still works over 443/tcp - slower,
but it connects.

---

## Checkpoint

```bash
tailscale status      # shows your machine
tailscale ip -4       # prints 100.x.y.z
```

Both working? Continue to [2. Docker on the VM](02-docker-server.md).

Problems? See [6. Troubleshooting](06-troubleshooting.md).
