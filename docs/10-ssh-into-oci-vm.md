# 10. SSH ke VM OCI dari Termux

Browser console OCI menyulitkan menyalin log. Panduan ini memberi Anda
terminal sungguhan di HP.

```bash
bash scripts/oci-vm-connect.sh --list
bash scripts/oci-vm-connect.sh --setup-key
bash scripts/oci-vm-connect.sh --connect <ip> --user ubuntu
```

---

## 10.1 Dua key yang berbeda — jangan tertukar

Ini penyebab kebingungan paling sering.

| | API signing key | SSH key |
|---|---|---|
| Berkas | `~/.oci/oci_api_key.pem` | `~/.ssh/id_ed25519` |
| Untuk | `oci` CLI, REST API | `ssh` ke VM |
| Format | PEM (`BEGIN PRIVATE KEY`) | OpenSSH |
| Algoritma | **RSA wajib** | RSA / ECDSA / Ed25519 |

**API key Anda tidak bisa dipakai untuk SSH**, dan sebaliknya. Keduanya
kebetulan berakhiran `.pem`, itu saja kesamaannya.

> Secara teknis kunci RSA *bisa* dikonversi
> (`ssh-keygen -y -f oci_api_key.pem`), tapi **jangan**. Satu kunci
> untuk dua tujuan berarti kalau bocor, penyerang dapat akses API
> *dan* shell sekaligus. Pisahkan.

---

## 10.2 Cari VM Anda

```bash
bash scripts/oci-vm-connect.sh --list
```

Menampilkan nama instance, shape, IP publik dan privat, serta OCID.

Kosong? VM Anda mungkin di compartment lain:

```bash
oci iam compartment list --output table
bash scripts/oci-vm-connect.sh --list --compartment ocid1.compartment.oc1..xxxx
```

Manual, kalau lebih suka:

```bash
export COMP=$(grep '^tenancy' ~/.oci/config | cut -d= -f2)
oci compute instance list --compartment-id "$COMP" --output table
oci compute instance list-vnics --instance-id <ocid> \
  --query 'data[0]."public-ip"' --raw-output
```

---

## 10.3 Siapkan kunci SSH

```bash
bash scripts/oci-vm-connect.sh --setup-key
```

Membuat `~/.ssh/id_ed25519` bila belum ada, lalu mencetak perintah yang
tinggal Anda tempel di VM.

### ⚠️ Cloud Shell BUKAN VM Anda

Kesalahan paling sering. Cloud Shell adalah mesin terpisah milik Oracle,
bukan instance Anda. Menambahkan kunci di sana **tidak memberi akses apa
pun** ke VM.

Perhatikan prompt:

```
ivansuselo@cloudshell:~ (ap-singapore-1)$     ← Cloud Shell, SALAH
opc@roc-vm:~$                                  ← VM Anda, BENAR
```

Kunci harus masuk ke `~/.ssh/authorized_keys` **di VM**.

### Mendaftarkan kunci di VM

Anda perlu masuk **sekali** untuk mendaftarkannya. Tiga cara:

**a. Cloud Shell sebagai batu loncatan.** Buka Cloud Shell, lalu SSH
dari sana ke VM. Ini tetap butuh kunci yang sudah dikenal VM — yaitu
kunci yang Anda pilih saat membuat instance:

```bash
# DI CLOUD SHELL
ssh -i ~/kunci-instance.key opc@<private-ip>
# sekarang prompt berubah jadi opc@roc-vm — barulah tempel kuncinya
```

Cloud Shell berada di VCN yang sama, jadi IP privat bisa dipakai.
Kalau kunci instance tidak ada di Cloud Shell, unggah lewat menu
**Cloud Shell → Upload**.

**b. Browser console** — Compute → Instance → Console connection. Repot
untuk mengetik, tapi cukup untuk satu baris `echo`.

**c. Kunci lama** — kalau sudah punya `.pem` dari saat membuat instance:

```bash
mv ~/Downloads/ssh-key-*.key ~/.ssh/oci-lama.pem
chmod 600 ~/.ssh/oci-lama.pem
ssh -i ~/.ssh/oci-lama.pem ubuntu@<ip>
```

Setelah masuk, di **VM**:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo 'ssh-ed25519 AAAA... termux-20260728' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

---

## 10.4 Buka port 22 di OCI

Berbeda dari AWS, OCI punya **dua lapis** firewall.

**Lapis 1 — Security List.** Port 22 biasanya sudah terbuka secara
default. Periksa: Networking → VCN → Subnet → Security List → Ingress
Rules, harus ada `0.0.0.0/0` port 22.

**Lapis 2 — iptables di host.** Image Ubuntu OCI membawa aturan REJECT
yang memblokir hampir semua port. SSH biasanya sudah dikecualikan, tapi
kalau bermasalah lihat [chapter 7](07-oci-vs-aws.md#the-big-oci-gotcha).

> Kalau nanti Anda memasang Tailscale ([chapter 1](01-tailscale-server.md)),
> kedua lapis ini jadi tidak relevan — dan port 22 publik bisa Anda tutup
> sepenuhnya.

---

## 10.5 Masuk

```bash
bash scripts/oci-vm-connect.sh --connect 140.238.x.x --user ubuntu
```

Atau langsung:

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@140.238.x.x
```

User default per image — **tidak bisa ditebak**, harus tepat:

| Image | User |
|---|---|
| Ubuntu | `ubuntu` |
| Oracle Linux | `opc` |
| Amazon Linux (AWS) | `ec2-user` |

---

## 10.6 Menyalin log — masalah yang Anda hadapi

Inilah alasan utama meninggalkan browser console.

### Salin ke clipboard Android

```bash
pkg install -y termux-api      # perlu app Termux:API dari F-Droid juga
ssh ubuntu@<ip> 'journalctl -u docker -n 100' | termux-clipboard-set
```

### Simpan ke berkas di HP

```bash
ssh ubuntu@<ip> 'docker logs myapp --tail 500' > ~/log.txt
ssh ubuntu@<ip> 'journalctl -n 200 --no-pager' > /sdcard/vm-log.txt
```

### Ikuti log secara langsung

```bash
ssh ubuntu@<ip> 'docker logs -f myapp'
```

Ctrl-C untuk berhenti. Scrollback Termux bisa Anda geser dan salin
dengan menekan lama.

### Sesi yang tahan putus koneksi

Sinyal HP terputus-putus. `tmux` di VM membuat pekerjaan Anda selamat:

```bash
ssh ubuntu@<ip> -t 'tmux new -A -s main'
```

Koneksi putus? Jalankan lagi perintah yang sama — Anda kembali persis di
tempat semula. Detach dengan `Ctrl-b d`.

### Salin berkas

```bash
scp ubuntu@<ip>:/var/log/syslog ~/syslog.txt          # ambil
scp ~/script.sh ubuntu@<ip>:~/                         # kirim
```

---

## 10.7 Membuat hidup lebih mudah

Tambahkan ke `~/.ssh/config` di HP:

```
Host ocivm
    HostName 140.238.x.x
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 30
    ServerAliveCountMax 4

Host awsvm
    HostName 54.x.x.x
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 30
```

Lalu cukup:

```bash
ssh ocivm
ssh awsvm
scp ocivm:/var/log/syslog ~/
```

`ServerAliveInterval` mencegah koneksi mati saat sinyal sesaat hilang —
sangat terasa bedanya di jaringan seluler.

---

## 10.8 Di Termux atau di dalam container?

**Di Termux langsung.** Kunci SSH sudah di sana, dan `ssh` adalah
program kecil tanpa dependensi berat.

Container `docker` punya kunci SSH sendiri, khusus untuk Docker
menjangkau daemon jarak jauh. Itu tugas berbeda — biarkan terpisah.

| | Termux | container |
|---|---|---|
| SSH interaktif, baca log | ✅ | tidak perlu |
| `DOCKER_HOST=ssh://...` | — | ✅ |

---

## 10.9 Kalau bermasalah

**`Permission denied (publickey)`**

```bash
ssh -v -i ~/.ssh/id_ed25519 ubuntu@<ip> 2>&1 | grep -iE 'offering|denied'
```

Biasanya: user salah, kunci belum di `authorized_keys`, atau permission
`~/.ssh` di VM terlalu longgar (`chmod 700 ~/.ssh`).

**`Connection timed out`** — Security List belum mengizinkan port 22,
atau IP-nya salah. Cek ulang dengan `--list`.

**Anda memakai IP privat.** `10.x`, `172.16–31.x` dan `192.168.x` hanya
bisa dijangkau dari dalam VCN — bukan dari HP. Pakai IP publik, atau
Tailscale.

**Kunci ditambahkan di Cloud Shell, bukan di VM.** Penyebab paling
umum. Lihat peringatan di atas.

**`Host key verification failed`** — VM dibangun ulang:

```bash
ssh-keygen -R <ip>
```

**Terputus terus** — pakai `tmux` (10.6) dan `ServerAliveInterval`
(10.7).

---

## 10.10 Sesudah ini

SSH hanya jalan masuk. Langkah tutorial yang sebenarnya:

1. [Tailscale di VM](01-tailscale-server.md) — setelah ini Anda bisa
   menutup port 22 publik sepenuhnya
2. [Docker di VM](02-docker-server.md)
3. [Menyambungkan](04-connect.md) — `docker ps` dari HP
