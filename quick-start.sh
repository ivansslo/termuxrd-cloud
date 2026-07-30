#!/usr/bin/env bash
# Quick-start menu for termuxrd-cloud

G='\033[32m'; Y='\033[33m'; C='\033[36m'; B='\033[1m'; N='\033[0m'

clear
echo -e "${B}TermuxRD-Cloud Manager${N}"
echo -e "------------------------"
echo -e "1) ${C}Setup Termux${N} (Langkah awal di Android)"
echo -e "2) ${C}Install OCI CLI${N} (Untuk Oracle Cloud)"
echo -e "3) ${C}Hunt ARM Capacity${N} (Mencari VM Gratis OCI)"
echo -e "4) ${C}Connect to VM${N} (Cek koneksi & Docker)"
echo -e "5) ${C}Healthcheck${N} (Diagnosa masalah)"
echo -e "q) Keluar"
echo

read -p "Pilih menu [1-5]: " pilihan

case $pilihan in
    1) bash scripts/termux-setup.sh ;;
    2) bash scripts/termux-oci-cli.sh ;;
    3) 
        read -p "Masukkan nama profil OCI (default): " prof
        [ -z "$prof" ] && bash scripts/oci-grab-arm.sh || bash scripts/oci-grab-arm.sh --profile "$prof"
        ;;
    4) bash scripts/oci-vm-connect.sh --list ;;
    5) bash scripts/healthcheck.sh ;;
    q) exit 0 ;;
    *) echo "Pilihan tidak valid"; sleep 2; bash "$0" ;;
esac
