# 7. Oracle Cloud vs AWS

The tutorial works identically on both. This chapter covers where they
differ, and how to tell which one you are actually on.

---

## Which am I on?

```bash
uname -r
```

| Kernel suffix | Platform |
|---|---|
| `-oracle` | Oracle Cloud (OCI) |
| `-aws` | Amazon EC2 |
| `-generic` | bare metal, or a generic VM image |
| `-azure`, `-gcp` | Azure, Google Cloud |

Ubuntu ships cloud-specific kernels, so this is a reliable signal. A
node reporting `6.14.0-1018-aws` is an EC2 instance, whatever the
machine is named.

Cross-check by asking the metadata service — each cloud has its own, and
only one will answer:

```bash
# OCI
curl -s -H 'Authorization: Bearer Oracle' --max-time 3 \
  http://169.254.169.254/opc/v2/instance/ | head -5

# AWS (IMDSv2)
TOKEN=$(curl -s -X PUT --max-time 3 \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
  http://169.254.169.254/latest/api/token) && \
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" --max-time 3 \
  http://169.254.169.254/latest/meta-data/instance-id
```

---

## The big OCI gotcha

**Oracle's Ubuntu images ship a host `iptables` rule that rejects almost
everything, in addition to cloud-level Security Lists.** Opening a port
in the console is *not enough*; people lose hours to this.

```bash
sudo iptables -L INPUT --line-numbers
```

You will see something like:

```
5   REJECT   all  --  anywhere   anywhere   reject-with icmp-host-prohibited
```

Anything below that line never matches. The rule commonly appears at
line 5 or 6.

### The correct fix

Insert your rule **above** the REJECT, rather than deleting the REJECT:

```bash
sudo iptables -I INPUT 5 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo netfilter-persistent save
```

Plenty of forum answers tell you to delete the REJECT line instead.
Don't. The default INPUT policy is `ACCEPT`, so removing it leaves the
host with effectively no firewall — every port open to the internet.
Inserting above it keeps the deny-by-default behaviour intact.

Oracle Linux uses `firewalld` rather than raw iptables:

```bash
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --reload
```

### Why this tutorial sidesteps it entirely

**Following this guide, you never open a port.** Tailscale is
outbound-only, so both the Security List and the iptables REJECT are
irrelevant. Services are reachable over `100.x.y.z` and nothing listens
on the public interface.

The section above is here for when you *do* need a genuinely public
port — a real website, say.

---

## Side by side

| | Oracle Cloud | AWS EC2 |
|---|---|---|
| Cloud firewall | Security List / NSG | Security Group |
| Host firewall preloaded | **yes** — iptables REJECT | no |
| Default users | `ubuntu`, `opc` | `ubuntu`, `ec2-user` |
| Free tier compute | 4 vCPU / 24 GB ARM, always free | t2/t3.micro, 12 months |
| Free egress | 10 TB/month | 100 GB/month |
| Metadata service | `/opc/v2/` | `/latest/meta-data/` |
| Block storage | 200 GB free | 30 GB free (12 months) |

For this use case OCI's free tier is markedly more generous — an
Ampere A1 with 4 cores and 24 GB runs a lot of containers. The tradeoff
is that ARM-only free capacity is often unavailable in popular regions,
and the iptables quirk catches newcomers.

---

## OCI: reclaiming an Ampere instance

Free ARM capacity is frequently exhausted, and the console reports
*Out of host capacity*. Instead of retrying by hand, script it with the
OCI CLI:

```bash
oci compute instance launch \
  --availability-domain "$AD" \
  --compartment-id "$OCI_COMPARTMENT" \
  --shape VM.Standard.A1.Flex \
  --shape-config '{"ocpus":4,"memoryInGBs":24}' \
  --image-id "$IMAGE_ID" \
  --subnet-id "$OCI_SUBNET" \
  --assign-public-ip true
```

Read those values from environment variables or the OCI config file —
never commit them. See [8. Security](08-security.md).

---

## OCI CLI setup, briefly

If you manage OCI from the command line, the CLI expects
`~/.oci/config`:

```ini
[DEFAULT]
user=ocid1.user.oc1..aaaa...
fingerprint=aa:bb:cc:...
tenancy=ocid1.tenancy.oc1..aaaa...
region=ap-singapore-1
key_file=~/.oci/oci_api_key.pem
```

```bash
chmod 600 ~/.oci/config ~/.oci/oci_api_key.pem
oci iam region list          # verify
```

The private key in `key_file` is the actual secret. The OCIDs and
fingerprint identify your account but cannot authenticate without it.
Keep all of it out of version control.

Running the CLI from Termux is possible inside a container:

```bash
rootd sh alpine -- sh -c 'apk add --no-cache py3-pip && pip install oci-cli'
```

Though in practice it is easier to run OCI commands on the VM itself,
over SSH.

---

## AWS notes

Security Groups are the only firewall; Ubuntu AMIs do not preload
iptables rules. Nothing to open for this tutorial regardless.

IMDSv2 is enforced on newer instances, which is why the metadata check
above requests a token first.

If you use the AWS CLI, prefer an **instance role** over static access
keys — no credentials to store or leak:

```bash
aws sts get-caller-identity     # works with no keys when a role is attached
```
