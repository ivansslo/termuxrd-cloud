# 5. Real workloads

Things worth actually running, now that the link works. Each assumes the
`dock` and `dc` helpers from [chapter 4](04-connect.md#45-make-it-comfortable).

---

## 5.1 Where files live — the one thing that trips everyone

The daemon runs on the VM. **Paths in your commands are resolved on the
VM, not on your phone.**

```bash
dock run -v /home/ubuntu/data:/data alpine ls /data   # VM's /home/ubuntu/data
dock run -v /sdcard/stuff:/data alpine ls /data       # does not exist on the VM
```

Same for builds: `docker build .` sends a *build context* — the daemon
never reads your phone's filesystem directly. Editing files on the phone
and building remotely means getting them to the VM first.

Simplest approach — edit on the VM over SSH:

```bash
rootd sh docker -- ssh ubuntu@100.x.y.z
```

Or sync a directory up:

```bash
rootd sh alpine -- sh -c 'apk add --no-cache rsync openssh-client && \
  rsync -avz ~/project/ ubuntu@100.x.y.z:~/project/'
```

---

## 5.2 A web service

```bash
dock run -d --name web -p 8080:80 --restart unless-stopped nginx:alpine
dock ps
```

Reach it from the phone over the tailnet:

```bash
curl http://100.x.y.z:8080
```

Or just open `http://100.x.y.z:8080` in your Android browser — the
Tailscale app routes it. **No Security List or Security Group rule
needed**, because the traffic arrives over the tunnel rather than the
public interface.

Clean up:

```bash
dock rm -f web
```

---

## 5.3 Nextcloud with Compose

Write the file on the VM:

```bash
rootd sh docker -- ssh ubuntu@100.x.y.z 'mkdir -p ~/stacks/nextcloud'
```

Then create `~/stacks/nextcloud/compose.yaml` on the VM
(an example is in [`examples/nextcloud-compose.yaml`](../examples/nextcloud-compose.yaml)):

```yaml
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD_FILE: /run/secrets/db_root
      MARIADB_DATABASE: nextcloud
      MARIADB_USER: nextcloud
      MARIADB_PASSWORD_FILE: /run/secrets/db_pass
    volumes:
      - db:/var/lib/mysql
    secrets: [db_root, db_pass]

  app:
    image: nextcloud:stable-apache
    restart: unless-stopped
    ports:
      - "8080:80"
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD_FILE: /run/secrets/db_pass
      NEXTCLOUD_TRUSTED_DOMAINS: "100.x.y.z myserver.tailnet-name.ts.net"
    volumes:
      - app:/var/www/html
    depends_on: [db]
    secrets: [db_pass]

volumes:
  db:
  app:

secrets:
  db_root:
    file: ./secrets/db_root.txt
  db_pass:
    file: ./secrets/db_pass.txt
```

Create the secret files on the VM — never inline passwords in the
compose file:

```bash
mkdir -p ~/stacks/nextcloud/secrets && cd ~/stacks/nextcloud
openssl rand -base64 32 > secrets/db_root.txt
openssl rand -base64 32 > secrets/db_pass.txt
chmod 600 secrets/*
```

Start it from the phone:

```bash
dc -f ~/stacks/nextcloud/compose.yaml up -d
dc -f ~/stacks/nextcloud/compose.yaml logs -f app
```

Open `http://100.x.y.z:8080`. Add your MagicDNS name to
`NEXTCLOUD_TRUSTED_DOMAINS` or Nextcloud will refuse the request.

---

## 5.4 Watching things

```bash
dock stats --no-stream          # CPU and memory per container
dock logs -f --tail 100 web     # follow logs
dock system df                  # disk usage
dock events                     # live daemon events
```

Reclaiming space on a small boot volume:

```bash
dock system prune -a --volumes  # careful: removes unused volumes too
```

---

## 5.5 Building images

Builds run on the VM, using its CPU. This is the real payoff — a phone
that cannot compile anything meaningful can drive a 4-core ARM builder.

```bash
rootd sh docker -- ssh ubuntu@100.x.y.z 'mkdir -p ~/build'
# put a Dockerfile in ~/build on the VM, then:
dock build -t myapp ~/build
dock run --rm myapp
```

Multi-arch, if you have set up Buildx:

```bash
dock buildx build --platform linux/amd64,linux/arm64 -t myapp:multi ~/build
```

---

## 5.6 Several VMs

Each container holds its own `DOCKER_HOST`, so one per server works
cleanly:

```bash
rootd install docker --name prod
rootd install docker --name dev

rootd docker prod --host ssh://ubuntu@100.64.0.10
rootd docker dev  --host ssh://opc@100.64.0.20

alias dprod='rootd sh prod -- docker'
alias ddev='rootd sh dev -- docker'

dprod ps
ddev ps
```

---

## 5.7 Portainer, for a UI

Typing on a phone is tedious. A web UI helps:

```bash
dock volume create portainer_data
dock run -d --name portainer --restart unless-stopped \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest
```

Open `https://100.x.y.z:9443` and set an admin password immediately.

> This mounts the Docker socket into a container — anyone who reaches
> that UI controls the host. It is only acceptable because the port is
> reachable solely over your tailnet. Never publish 9443 publicly.

---

Continue to [6. Troubleshooting](06-troubleshooting.md).
