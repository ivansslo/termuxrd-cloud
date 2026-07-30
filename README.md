# termuxrd-cloud

Run Docker on a cloud VM from your Android phone, over Tailscale.

Your phone becomes the terminal; the VM does the work. No public ports,
no port forwarding, no exposed Docker socket.

```
┌─────────────┐        encrypted tailnet         ┌──────────────────┐
│   Termux    │  ◄──────────────────────────────► │  Cloud VM        │
│   + rootd   │         100.x.y.z                 │  dockerd + apps  │
│   docker CLI│                                   │  (OCI or EC2)    │
└─────────────┘                                   └──────────────────┘
        │                                                   ▲
        └──────── DOCKER_HOST=ssh://user@100.x.y.z ─────────┘
```

Built on [termuxrd](https://github.com/ivansslo/termuxrd) and
[rootd-fs](https://github.com/ivansslo/rootd-fs).

---

## Read this first

**A Docker daemon cannot run on a stock Android kernel.** It needs real
root, cgroups, overlayfs and veth pairs - none of which an unprivileged
Android app has. Guides promising "Docker in Termux" are either using a
rooted device with a custom kernel, or they do not work.

This guide does the thing that *does* work: run the Docker **client** on
your phone against a real daemon on a real Linux VM. That is how the
Docker CLI was designed - it has always been a REST client over a
socket. You get the complete command set, backed by the server's real
cgroups and real storage driver.

Check your own device honestly:

```bash
rootd caps
```

---

## Tutorial

| # | Guide | Time |
|---|---|---|
| 1 | [Tailscale on the VM](docs/01-tailscale-server.md) | 10 min |
| 2 | [Docker on the VM](docs/02-docker-server.md) | 10 min |
| 3 | [Termux setup](docs/03-termux-setup.md) | 15 min |
| 4 | [Connecting the two](docs/04-connect.md) | 10 min |
| 5 | [Real workloads](docs/05-workloads.md) | - |
| 6 | [Troubleshooting](docs/06-troubleshooting.md) | - |
| 7 | [OCI vs AWS differences](docs/07-oci-vs-aws.md) | - |
| 8 | [Security](docs/08-security.md) | read it |
| 9 | [OCI CLI on Termux](docs/09-oci-cli-termux.md) | 10 min |
| 10 | [SSH into an OCI VM](docs/10-ssh-into-oci-vm.md) | 10 min |
| 11 | [Always Free ARM capacity](docs/11-free-tier-capacity.md) | read when stuck |

New to this? Follow 1 → 4 in order. It takes about 45 minutes.

---

## The short version

If you already know your way around, this is the whole thing.

**On the VM:**

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh --hostname=myserver
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER" && newgrp docker
tailscale ip -4          # note this address
```

**On the phone:**

```bash
pkg install python proot git curl openssh
curl -fsSL https://raw.githubusercontent.com/ivansslo/termuxrd/v1.0.0/install.sh -o i.sh
bash i.sh --yes --distro alpine

ssh-keygen -t ed25519          # then add the .pub to the VM
rootd docker alpine --host ssh://ubuntu@100.x.y.z
rootd sh alpine -- docker ps
```

That is it. No inbound firewall rules on either side.

---

## Why no ports need opening

Tailscale is outbound-only. Both machines dial out to the coordination
server and negotiate a direct WireGuard tunnel, or fall back to an
encrypted DERP relay. Nothing listens on your VM's public interface.

This matters practically: on Oracle Cloud you can skip Security Lists
*and* the notorious host `iptables` REJECT rule entirely. On AWS you can
leave the Security Group closed. Fewer moving parts, and a much smaller
attack surface than exposing `dockerd` on `tcp://2375`.

> Never expose the Docker daemon on a public TCP port. An unauthenticated
> daemon port is root on that host for anyone who can reach it.

---

## Scripts

Convenience wrappers for the manual steps. Read them before running -
that advice applies to every script, including these.

| Script | Runs on | Does |
|---|---|---|
| [`scripts/server-bootstrap.sh`](scripts/server-bootstrap.sh) | VM | Tailscale + Docker + hardening |
| [`scripts/termux-setup.sh`](scripts/termux-setup.sh) | phone | termuxrd + SSH key + client wiring |
| [`scripts/healthcheck.sh`](scripts/healthcheck.sh) | phone | diagnose a broken link |
| [`scripts/termux-oci-cli.sh`](scripts/termux-oci-cli.sh) | phone | install the OCI CLI (Oracle's installer cannot) |
| [`scripts/oci-vm-connect.sh`](scripts/oci-vm-connect.sh) | phone | find OCI instances and SSH in |
| [`scripts/oci-grab-arm.sh`](scripts/oci-grab-arm.sh) | phone | retry until Always Free ARM capacity appears |

---

## Requirements

**VM** - any Linux with 1 GB RAM. Oracle Cloud Free Tier (4 vCPU /
24 GB ARM) and AWS free tier both work.

**Phone** - Termux from [F-Droid](https://f-droid.org/packages/com.termux/)
or GitHub. *Not* the Play Store build; it is outdated and its packages
break.

**Account** - a free [Tailscale](https://tailscale.com) account. Up to
100 devices.

---

## Credentials

This repository contains **no real credentials**, and you should not add
any. Every example uses placeholders:

| Placeholder | Meaning |
|---|---|
| `100.x.y.z` | your VM's Tailscale IP |
| `ubuntu@` | your VM's login user |
| `myserver` | your VM's tailnet name |

See [docs/08-security.md](docs/08-security.md) for how to store real
secrets, and what to do if you have already pasted one somewhere.

---

## License

MIT - see [LICENSE](LICENSE).

Not affiliated with Tailscale Inc., Docker Inc., Oracle, Amazon, or the
Termux project. Product names are used only to describe interoperability.
