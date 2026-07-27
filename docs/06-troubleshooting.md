# 6. Troubleshooting

Work top to bottom — the checks are ordered so each one rules out a
layer.

Quick automated pass:

```bash
bash scripts/healthcheck.sh
```

---

## Diagnose in layers

```
phone container → phone network → tailnet → VM SSH → VM docker daemon
```

```bash
rootd ls                                   # 1. container exists
ping -c 3 100.x.y.z                        # 2. tailnet reachable
rootd sh docker -- ssh ubuntu@100.x.y.z hostname   # 3. SSH works
rootd sh docker -- docker version          # 4. daemon answers
```

The first failing step is where to focus.

---

## No ping

**Is Tailscale actually connected on both ends?**

Phone: open the Tailscale app; it should say *Connected*.
VM: `tailscale status`.

**Is the address right?** Re-check on the VM:

```bash
tailscale ip -4
```

**Did the node key expire?** Very common after ~180 days. The admin
console shows the machine as expired. Fix and prevent:

```bash
sudo tailscale up --ssh --hostname=myserver
```

then **Machines → ⋯ → Disable key expiry**.

**Is another VPN running on the phone?** Android allows only one. Turn
the other off.

**Is the tunnel relayed and slow, or dead?**

```bash
tailscale netcheck
tailscale ping 100.x.y.z
```

`via DERP` means it fell back to a relay — working but slower. `via
direct` is ideal. Neither means the tunnel is down.

---

## SSH asks for a password

The key is not being offered or not accepted.

**Is the public key on the VM, exactly one line?**

```bash
cat ~/.ssh/authorized_keys
```

**Permissions?** SSH silently refuses keys in loose directories:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

**Right user?** `ubuntu`, `opc`, and `ec2-user` are not interchangeable.

**Ask SSH what it is doing** — this almost always reveals the cause:

```bash
rootd sh docker -- ssh -v ubuntu@100.x.y.z 2>&1 | grep -i -E 'offering|denied|auth'
```

---

## `docker: command not found`

Inside the container, not on the phone:

```bash
rootd sh docker -- which docker || rootd sh docker -- apk add --no-cache docker-cli
```

---

## `Cannot connect to the Docker daemon`

**Is `DOCKER_HOST` set?**

```bash
rootd docker docker
```

Empty? Set it:

```bash
rootd docker docker --host ssh://ubuntu@100.x.y.z
```

**Is the daemon running on the VM?**

```bash
rootd sh docker -- ssh ubuntu@100.x.y.z 'systemctl is-active docker'
```

**Does your user have socket access?** On the VM:

```bash
groups                   # 'docker' should be listed
sudo usermod -aG docker "$USER" && newgrp docker
```

---

## `ssh: Could not resolve hostname`

Use the numeric `100.x.y.z` rather than a MagicDNS name. MagicDNS
resolution inside a rootless container is unreliable — the container
does not inherit Android's resolver.

If you want names, add a hosts entry inside the container:

```bash
rootd sh docker -- sh -c 'echo "100.x.y.z myserver" >> /etc/hosts'
```

---

## `Host key verification failed`

First connection, or the VM was rebuilt:

```bash
rootd sh docker -- ssh -o StrictHostKeyChecking=accept-new ubuntu@100.x.y.z hostname
```

If the VM was genuinely rebuilt, drop the stale entry:

```bash
rootd sh docker -- ssh-keygen -R 100.x.y.z
```

---

## Everything works, but it is slow

```bash
tailscale ping 100.x.y.z
```

`via DERP` means relayed traffic. Usually the phone is on a carrier NAT
that blocks direct UDP. Options: switch to Wi-Fi, or accept the relay —
it is encrypted and adequate for a terminal.

Also check the VM is not simply out of memory:

```bash
rootd sh docker -- ssh ubuntu@100.x.y.z 'free -h; uptime'
```

Add swap if it is thrashing — see
[2.6](02-docker-server.md#26-optional-swap-for-a-small-vm).

---

## Termux killed in the background

Android aggressively stops background apps.

- Settings → Apps → Termux → Battery → **Unrestricted**
- Enable Termux's persistent notification (it makes the process
  foreground and much harder to kill)
- Some vendors — Xiaomi, Oppo, Vivo, Huawei — need Termux added to an
  explicit autostart allowlist. See [dontkillmyapp.com](https://dontkillmyapp.com).

---

## Stuck inside a container at every launch

You enabled autostart and something broke.

```bash
ROOTD_NO_AUTO=1 bash
rootd autostart off
```

The hook is designed to fall through to the host shell when the
container is unavailable, so this should be rare — but the escape hatch
exists regardless.

---

## `proot error: unknown option`

Your `proot` is older than the flags rootd-fs wants. Fixed in rootd-fs
v0.5.1, which probes what the installed build supports:

```bash
pip install --user --upgrade rootd-fs
```

---

## Out of disk on the VM

```bash
rootd sh docker -- ssh ubuntu@100.x.y.z 'df -h /'
dock system df
dock system prune -a
```

Unbounded container logs are the usual culprit — see
[2.7](02-docker-server.md#27-optional-cap-the-logs).

---

## Starting over

Phone side, without touching the VM:

```bash
rootd purge                    # removes every container and cache
bash install.sh --uninstall    # removes the shell hook
```

---

## Still stuck

Gather this before asking anywhere:

```bash
rootd --version
rootd caps
rootd ls
tailscale status          # on the VM
docker info               # on the VM
```

**Redact** IP addresses, hostnames and usernames before posting them
publicly.
