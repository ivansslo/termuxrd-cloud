# 3. Termux setup

**Goal:** termuxrd installed, a container ready, and the phone joined to
your tailnet.

Time: about 15 minutes.

---

## 3.1 Install Termux from the right place

Get Termux from **[F-Droid](https://f-droid.org/packages/com.termux/)**
or [GitHub releases](https://github.com/termux/termux-app/releases).

**Not the Play Store build.** It is frozen at an old version, its package
repositories no longer resolve, and installs fail in confusing ways. If
you already have it, uninstall first — the two signatures conflict.

---

## 3.2 Base packages

```bash
pkg update -y && pkg upgrade -y
pkg install -y python proot git curl openssh
```

Storage access, if you want backups on `/sdcard`:

```bash
termux-setup-storage      # grant the permission prompt
```

---

## 3.3 Install termuxrd

```bash
curl -fsSL https://raw.githubusercontent.com/ivansslo/termuxrd/v1.0.0/install.sh -o install.sh
less install.sh           # read it
bash install.sh --distro alpine
```

Alpine is a good default here: about 8 MB, and the Docker client is all
we need inside it. Use `--distro ubuntu` if you want a fuller userland.

The installer shows a plan and asks before changing anything. When it
offers autostart, **say no for now** — get things working manually
first, then enable it in [chapter 4](04-connect.md).

Verify:

```bash
rootd --version
rootd ls
rootd caps        # honest report of what this kernel supports
```

`rootd caps` will confirm that a local Docker daemon is impossible here.
That is expected, and the whole reason for this guide.

---

## 3.4 Install the Docker client

The client is a single static binary, and rootd-fs ships a preset:

```bash
rootd install docker
```

That pulls the official `docker:cli` image (about 150 MB) into a
container named `docker`. Check it:

```bash
rootd sh docker -- docker --version
```

You should see something like `Docker version 27.x.x`. It cannot do
anything yet — there is no daemon to talk to. That is chapter 4.

### Alternative: client inside your Alpine box

If you would rather keep one container:

```bash
rootd sh alpine -- apk add --no-cache docker-cli docker-cli-compose openssh-client
rootd sh alpine -- docker --version
```

Smaller, and puts the SSH client in the same place.

---

## 3.5 Tailscale on the phone

Two options. Pick one.

### Option A — the Android app (recommended)

Install **Tailscale** from the Play Store or F-Droid, sign in, connect.
It uses Android's VPN API, so *everything* on the phone — including
Termux — can reach your tailnet.

Simple, reliable, and it survives reboots.

One caveat: Android permits a single active VPN. If you already use
another VPN, you cannot run both, and Option B becomes relevant.

### Option B — tailscaled inside a container

```bash
rootd install tailscale
```

Then in one Termux session:

```bash
rootd tailscale tailscale daemon
```

and in a second session (swipe from the left edge → **New session**):

```bash
rootd tailscale tailscale up --ssh --hostname=my-phone
```

**Understand the limitation.** `/dev/net/tun` is not usable by an
unprivileged Android process, so this runs in *userspace networking*
mode. Consequences:

- the phone **is** reachable from your tailnet — your VM can SSH in;
- traffic *from* the container can egress through a SOCKS5 proxy on
  `localhost:1055`;
- it does **not** create a phone-wide VPN. Other apps, and Termux
  outside that container, keep using the normal network.

For this tutorial that is usually enough, but Option A is less friction.

---

## 3.6 Confirm the phone can see the VM

With Option A:

```bash
ping -c 3 100.x.y.z
```

Substitute the address from [chapter 1](01-tailscale-server.md#14-note-the-address).

Replies mean the tunnel is up and you can continue. No replies? See
[6. Troubleshooting](06-troubleshooting.md#no-ping).

With Option B, test from inside the container instead:

```bash
rootd sh tailscale -- tailscale status
```

---

## Checkpoint

```bash
rootd ls                        # alpine and docker present
rootd sh docker -- docker --version
ping -c 3 100.x.y.z             # VM reachable
```

Continue to [4. Connecting the two](04-connect.md).
