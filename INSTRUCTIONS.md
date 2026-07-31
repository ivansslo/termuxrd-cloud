# Panduan Cepat TermuxRD-Cloud

Saya telah memperbaiki skrip di repositori ini agar lebih stabil (menghapus karakter khusus yang menyebabkan error sintaks pada Bash).

## Cara Menggunakan

### 1. Jalankan Menu Utama
Gunakan skrip menu yang baru saya buat untuk mempermudah navigasi:
```bash
cd repo_analysis
chmod +x quick-start.sh
./quick-start.sh
```

### 2. Alur Setup yang Disarankan
1.  **Pilih Menu 1 (Setup Termux)**: Menginstal dependensi dasar di Android Anda.
2.  **Pilih Menu 2 (Install OCI CLI)**: Jika Anda menggunakan Oracle Cloud.
3.  **Konfigurasi OCI**: Jalankan `oci setup config` (jika diminta oleh skrip).
4.  **Opsi 'p' (Switch Profile)**: Untuk beralih ke profil OCI lainnya jika Anda menggunakan Multi-Profile.
5.  **Pilih Menu 3 (Hunt ARM)**: Untuk mencari kapasitas VM gratis yang sering penuh.
6.  **Pilih Menu 5 (Local Box)**: Untuk setup Tailscale lokal di dalam box (jika diperlukan).

## Perbaikan yang Dilakukan
*   **Multi-Profile Support**: Skrip `termux-oci-cli.sh --repair-config` sekarang mendukung banyak profil. Sebelumnya, menjalankan ini akan menghapus semua profil kecuali satu.
*   **OCI Import Tool**: `scripts/oci-env-to-config.sh` untuk menarik data dari file `.env` ke profil OCI tertentu — dijalankan manual (`bash scripts/oci-env-to-config.sh <path> <profil>`), tidak lagi ada di menu utama (menu "Import OCI Profile" dihapus 2026-08-01; alur onboarding profil baru cukup lewat `oci setup config` + opsi 'p').
*   **Fix Syntax Errors**: Menghapus karakter non-standard (em-dash, smart quotes) yang sering kali muncul akibat copy-paste dan merusak parsing shell.
*   **Safe Quick Menu**: Membuat file `quick-start.sh` sebagai hub pusat semua alat dalam repositori ini dan `rootd-fs`.

---
*Catatan: Pastikan Anda sudah memiliki akun Tailscale untuk koneksi yang aman.*
