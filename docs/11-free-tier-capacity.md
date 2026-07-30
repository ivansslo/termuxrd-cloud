# 11. Kapasitas Always Free ARM

Cara membedakan "tunggu saja" dari "ubah rencana".

---

## 11.1 Dua kegagalan yang sangat berbeda

| Pesan | Artinya | Sikap |
|---|---|---|
| `no capacity` | permintaan **diproses**, host memang penuh | ✅ normal, lanjut menunggu |
| `rate limited` (HTTP 429) | permintaan **ditolak** sebelum diperiksa | ⚠️ berhenti, mundur |

Bedanya penting. Saat `no capacity`, Anda benar-benar mengantre. Saat
`rate limited`, kapasitas **tidak pernah dicek sama sekali** - seratus
percobaan sama dengan nol pemeriksaan, dan Anda bisa melewatkan momen
kosong tanpa sadar.

Mencoba lagi terlalu cepat setelah 429 biasanya **memperpanjang** masa
throttle. Script menangani ini dengan mundur bertahap: 2, 4, 8, 16, lalu
30 menit.

---

## 11.2 Kalau sudah kena throttle

**Berhenti dulu satu jam.** Ini terasa berlawanan dengan naluri, tapi
selama throttled Anda tidak sedang mengantre - hanya membuang baterai.

```bash
# Ctrl-C, tunggu ~1 jam, lalu lebih santai:
bash scripts/oci-grab-arm.sh --ocpus 1 --mem 6 --interval 1800
```

Interval 30 menit = 48 percobaan sehari, semuanya benar-benar diperiksa.
Itu jauh lebih berguna daripada 300 percobaan yang ditolak.

---

## 11.3 Berapa lama biasanya?

Tidak ada jaminan. Kapasitas ARM gratis dilepas saat ada pengguna lain
menghapus instance, jadi sifatnya rebutan.

Laporan komunitas berkisar dari **beberapa jam sampai beberapa minggu**,
tergantung region. Singapura termasuk yang padat.

Yang menaikkan peluang:

| Faktor | Pengaruh |
|---|---|
| 1 OCPU, bukan 4 | **besar** - butuh satu core bebas, bukan empat |
| Interval wajar | **besar** - hindari throttle |
| Boot volume kecil (50 GB) | kecil |
| Jam sepi (dini hari) | kecil |
| Ganti AD | **nol** di region satu-AD seperti Singapura |

---

## 11.4 Jangan pindah region

Always Free hanya berlaku di **home region** Anda. Membuat instance di
Tokyo atau Mumbai akan **ditagih**, bukan gratis.

Home region tidak bisa diganti setelah akun dibuat.

---

## 11.5 Alternatif: mulai dengan x86 sekarang

Ini yang saya sarankan kalau Anda tidak ingin menunggu berhari-hari.

**`VM.Standard.E2.1.Micro`** - AMD x86, juga *Always Free*, dan hampir
selalu tersedia karena jauh lebih sedikit peminatnya.

| | A1.Flex (ARM) | E2.1.Micro (x86) |
|---|---|---|
| Jatah gratis | 4 OCPU / 24 GB | 2 instance × 1 GB |
| Ketersediaan | sering habis | hampir selalu ada |
| Cukup untuk Tailscale | ya | ya |
| Cukup untuk Docker | ya | ya, yang ringan |
| Nextcloud + database | nyaman | sempit |

**Keduanya boleh jalan bersamaan.** Jadi ambil E2 sekarang untuk
menyelesaikan tutorial, dan biarkan pemburu ARM berjalan di latar. Saat
dapat, pindahkan beban kerja - atau simpan keduanya.

Buat lewat CLI:

```bash
export COMP=$(grep '^tenancy' ~/.oci/config | cut -d= -f2)
export AD=$(oci iam availability-domain list --query 'data[0].name' --raw-output)
export SUBNET=$(oci network subnet list --compartment-id "$COMP" \
  --query 'data[0].id' --raw-output)
export IMAGE=$(oci compute image list --compartment-id "$COMP" \
  --operating-system "Canonical Ubuntu" --shape VM.Standard.E2.1.Micro \
  --sort-by TIMECREATED --query 'data[0].id' --raw-output)

oci compute instance launch \
  --availability-domain "$AD" \
  --compartment-id "$COMP" \
  --display-name roc-vm-x86 \
  --shape VM.Standard.E2.1.Micro \
  --image-id "$IMAGE" \
  --subnet-id "$SUBNET" \
  --assign-public-ip true \
  --ssh-authorized-keys-file ~/.ssh/id_ed25519.pub \
  --wait-for-state RUNNING
```

Atau lewat Console: **Change shape → Specialty and legacy →
VM.Standard.E2.1.Micro**.

> Dengan RAM 1 GB, tambahkan swap sebelum menjalankan Docker - lihat
> [2.6](02-docker-server.md#26-optional-swap-for-a-small-vm).

---

## 11.6 Menjaga Termux tetap hidup

Perburuan panjang tidak berguna kalau Android membunuh Termux.

```bash
termux-wake-lock
```

Dan di sistem:

- Setelan → Apps → Termux → Baterai → **Tanpa batasan**
- Aktifkan notifikasi persisten Termux
- Xiaomi, Oppo, Vivo, Huawei perlu autostart allowlist -
  [dontkillmyapp.com](https://dontkillmyapp.com)

Cara paling andal justru **menjalankan pemburu di server lain** yang
sudah Anda punya (misalnya VM AWS), supaya tidak bergantung pada HP:

```bash
scp ~/.oci/config ~/.oci/*.pem ubuntu@<aws-ip>:~/.oci/
scp scripts/oci-grab-arm.sh ubuntu@<aws-ip>:~/
ssh ubuntu@<aws-ip> 'tmux new -d -s hunt "bash ~/oci-grab-arm.sh --ocpus 1 --mem 6 --interval 1800"'
```

⚠️ Ini menaruh private key OCI Anda di mesin kedua. Kalau melakukannya,
pertimbangkan user OCI terpisah dengan policy terbatas -
[chapter 9.7](09-oci-cli-termux.md#97-security).

---

## 11.7 Ringkasan

```
rate limited?  → berhenti 1 jam, lalu --interval 1800
no capacity?   → biarkan berjalan, itu antrean yang benar
buru-buru?     → ambil E2.1.Micro sekarang, ARM menyusul
```
