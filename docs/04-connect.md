# 4. Connecting the two

**Goal:** `docker ps` on your phone, listing containers on your VM.

Time: about 10 minutes.

---

## 4.1 Generate an SSH key

Docker's `ssh://` transport uses your normal SSH client, so it needs a
key. Keep the key **inside the container** that will use it — then
`rootd backup` captures it along with everything else.

```bash
rootd sh docker -- sh -c 'apk add --no-cache openssh-client 2>/dev/null; \
  mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
  ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -C phone && \
  cat /root/.ssh/id_ed25519.pub'
```

Copy the `ssh-ed25519 AAAA...` line it prints.

rootd-fs also has a shortcut for this:

```bash
rootd ssh docker --keygen
```

### Using Tailscale SSH instead

If you enabled `--ssh` on the VM, you can skip keys entirely — the
tailnet authenticates you. Jump to [4.3](#43-point-the-client-at-the-vm)
and test with `tailscale ssh` first. Keys are still worth having as a
fallback for when the Tailscale SSH policy is not what you expected.

---

## 4.2 Authorise the key on the VM

On the **VM**:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo 'ssh-ed25519 AAAA... phone' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Paste the exact line from the previous step.

Test from the phone:

```bash
rootd sh docker -- ssh -o StrictHostKeyChecking=accept-new ubuntu@100.x.y.z 'hostname'
```

It should print your VM's hostname. If it asks for a password, the key
is not being accepted — see
[troubleshooting](06-troubleshooting.md#ssh-asks-for-a-password).

---

## 4.3 Point the client at the VM

```bash
rootd docker docker --host ssh://ubuntu@100.x.y.z
```

This records `DOCKER_HOST` in the container's metadata, so it persists
across sessions and survives backup and restore.

Check what is configured at any time:

```bash
rootd docker docker
```

---

## 4.3b Let the container trust the VM's host key

Almost everyone hits this once:

```
error during connect: ... exited with exit status 255
stderr=Host key verification failed.
```

Two things combine to cause it:

- `docker --host ssh://...` runs `ssh -T ... docker system dial-stdio`.
  With **no TTY**, ssh cannot ask *"trust this host?"* — it just fails.
- The container keeps its **own** `known_hosts`. Verifying the host from
  Termux earlier did nothing for the box.

Fix it once:

```bash
bash scripts/oci-vm-connect.sh --trust-host 100.x.y.z
```

It shows the fingerprints, asks you to confirm, then writes them into
the container's `known_hosts`.

By hand, if you prefer:

```bash
ssh-keyscan -T 10 100.x.y.z | \
  rootd sh docker -- sh -c 'mkdir -p /root/.ssh && cat >> /root/.ssh/known_hosts'
```

> Do not reach for `StrictHostKeyChecking=no`. It disables the check
> that would warn you about a man-in-the-middle, and you only need to do
> this once per host.

---

## 4.4 The moment of truth

```bash
rootd sh docker -- docker version
```

You should see **both** a Client and a Server block. The Server section
is your VM — its version, its kernel, its architecture.

```bash
rootd sh docker -- docker ps
rootd sh docker -- docker info | head -20
```

You are now driving a real Docker daemon from your phone.

---

## 4.5 Make it comfortable

Typing `rootd sh docker -- docker ...` gets old immediately. Add a
shell function to `~/.bashrc` **on the phone**:

```bash
cat >> ~/.bashrc <<'EOF'

# Docker on the cloud VM, via tailnet
dock() { rootd sh docker -- docker "$@"; }
dc()   { rootd sh docker -- docker compose "$@"; }
EOF
source ~/.bashrc
```

Now:

```bash
dock ps
dock images
dc up -d
```

---

## 4.6 Optional: open the container on every launch

If you want Termux to drop straight into the container:

```bash
rootd autostart on docker
```

This appends a **marked, reversible block** to `~/.bashrc`, keeping a
`.rootd-bak` copy first. It is written to fail safe: interactive shells
only, no recursion, and it falls through to the host shell if the
container is unavailable.

Escape hatch, should you ever need it:

```bash
ROOTD_NO_AUTO=1 bash
rootd autostart off
```

---

## 4.7 Back up the working setup

Now that everything works, capture it — including the SSH key and the
`DOCKER_HOST` setting:

```bash
rootd backup docker -o /sdcard/docker-box.tar.xz
```

Restoring on a new phone:

```bash
rootd restore /sdcard/docker-box.tar.xz
```

That is the whole setup, minus the pairing.

---

## Checkpoint

```bash
dock version      # Client AND Server
dock ps           # VM's containers
```

Continue to [5. Real workloads](05-workloads.md).
