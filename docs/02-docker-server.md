# 2. Docker on the VM

**Goal:** a working Docker daemon, reachable only over your tailnet.

Time: about 10 minutes.

---

## 2.1 Install Docker Engine

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
less get-docker.sh          # worth a look
sh get-docker.sh
```

This installs Docker Engine, the CLI, containerd, and the Compose and
Buildx plugins.

### Oracle Linux 8/9

The convenience script does not support it. Use `dnf`:

```bash
sudo dnf install -y dnf-utils
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io \
                    docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
```

---

## 2.2 Run Docker without sudo

```bash
sudo usermod -aG docker "$USER"
newgrp docker          # applies to this shell; a re-login also works
```

Verify:

```bash
docker run --rm hello-world
```

If you see *permission denied on /var/run/docker.sock*, the group change
has not taken effect — log out and back in.

> Membership of the `docker` group is equivalent to root on this host: a
> container can mount `/` and modify anything. Only grant it to accounts
> you would already trust with `sudo`.

---

## 2.3 Enable on boot

```bash
sudo systemctl enable --now docker containerd
systemctl is-enabled docker      # -> enabled
```

---

## 2.4 Verify containerd

Docker uses containerd underneath. It is installed and running as a
dependency; you rarely touch it directly.

```bash
systemctl status containerd --no-pager | head -5
docker info | grep -i -E 'server version|storage driver|cgroup'
```

Healthy output looks roughly like:

```
Server Version: 27.x.x
Storage Driver: overlay2
Cgroup Driver: systemd
Cgroup Version: 2
```

`overlay2` and cgroup v2 are what a real kernel provides — and exactly
what Android cannot, which is why the daemon lives here and not on your
phone.

---

## 2.5 Do not expose the daemon on TCP

You may find guides suggesting this:

```bash
# DO NOT DO THIS
dockerd -H tcp://0.0.0.0:2375
```

That is an unauthenticated root shell for anyone who can reach the port.
Internet-wide scanners find such hosts within minutes and use them for
cryptomining and worse.

**Leave the daemon on its local Unix socket.** The next chapters reach it
over SSH through the tailnet, which is authenticated and encrypted, and
requires no listening port at all.

Confirm nothing is listening publicly:

```bash
sudo ss -tlnp | grep -E '2375|2376' || echo "clean — daemon is socket-only"
```

---

## 2.6 Optional: swap for a small VM

Builds get killed by the OOM reaper on 1 GB instances. Two gigabytes of
swap costs nothing:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

---

## 2.7 Optional: cap the logs

Container logs grow without limit by default and will eventually fill a
small boot volume.

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
sudo systemctl restart docker
```

---

## Checkpoint

```bash
docker run --rm hello-world     # works without sudo
docker compose version          # plugin present
tailscale ip -4                 # address noted
```

Continue to [3. Termux setup](03-termux-setup.md).
