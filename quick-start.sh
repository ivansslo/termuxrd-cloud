#!/usr/bin/env bash
# Quick-start menu for termuxrd-cloud & rootd-fs

G='\033[32m'; Y='\033[33m'; R='\033[31m'; C='\033[36m'; B='\033[1m'; N='\033[0m'

# Global OCI Profile
OCI_PROFILE="DEFAULT"

main_menu() {
    clear
    echo -e "${B}TermuxRD-Cloud & rootd-fs Manager${N}"
    echo -e "------------------------------------"
    echo -e "Active OCI Profile: ${Y}${OCI_PROFILE}${N}"
    echo -e "------------------------------------"
    echo -e "1) ${C}Setup Termux${N} (Initial Android setup)"
    echo -e "2) ${C}Install OCI CLI${N} (Oracle Cloud management)"
    echo -e "3) ${C}Hunt ARM Capacity${N} (Find Always Free VMs)"
    echo -e "4) ${C}Cloud VM Connection${N} (Manage Cloud SSH/IPs)"
    echo -e "5) ${C}Local Box Tooling${N} (Tailscale & SSH via rootd-fs)"
    echo -e "6) ${C}Healthcheck${N} (Diagnose setup)"
    echo -e "p) ${Y}Switch OCI Profile${N}"
    echo -e "q) Exit"
    echo

    read -p "Select [1-6/p/q]: " pilihan

    case $pilihan in
        1) bash scripts/termux-setup.sh ;;
        2) bash scripts/termux-oci-cli.sh ;;
        3) 
            bash scripts/oci-grab-arm.sh --profile "$OCI_PROFILE"
            read -p "Press Enter to continue..."
            main_menu
            ;;
        4) cloud_vm_menu ;;
        5) local_box_menu ;;
        6) bash scripts/healthcheck.sh ; read -p "Press Enter to continue..." ; main_menu ;;
        p) 
            echo -e "\n${B}Available OCI Profiles in ~/.oci/config:${N}"
            if [ -f "$HOME/.oci/config" ]; then
                grep "\[" "$HOME/.oci/config" | tr -d '[]'
            else
                echo -e "${R}No ~/.oci/config found.${N}"
            fi
            echo
            read -p "Enter profile name to use: " new_prof
            if [ -n "$new_prof" ]; then
                OCI_PROFILE="$new_prof"
            fi
            main_menu
            ;;
        q) exit 0 ;;
        *) echo "Invalid choice"; sleep 1; main_menu ;;
    esac
}

cloud_vm_menu() {
    clear
    echo -e "${B}Cloud VM Connection Menu${N} (Profile: ${Y}${OCI_PROFILE}${N})"
    echo -e "------------------------------------"
    echo -e "1) List OCI Instances"
    echo -e "2) Setup SSH Key for Cloud"
    echo -e "3) Connect to VM (SSH)"
    echo -e "b) Back"
    echo
    read -p "Option: " c_opt
    case $c_opt in
        1) 
            bash scripts/oci-vm-connect.sh --list --profile "$OCI_PROFILE"
            read -p "Press Enter to continue..."
            cloud_vm_menu
            ;;
        2) 
            bash scripts/oci-vm-connect.sh --setup-key
            read -p "Press Enter to continue..."
            cloud_vm_menu
            ;;
        3) 
            read -p "Target IP: " target
            read -p "User (default: ubuntu): " user
            user=${user:-ubuntu}
            bash scripts/oci-vm-connect.sh --connect "$target" --user "$user"
            read -p "Press Enter to continue..."
            cloud_vm_menu
            ;;
        *) main_menu ;;
    esac
}

local_box_menu() {
    clear
    echo -e "${B}Local Box Tooling (rootd-fs)${N}"
    echo -e "-----------------------------"
    echo -e "1) ${G}Tailscale Menu${N} (Local VPN box)"
    echo -e "2) ${G}SSH Menu${N} (In-box SSH client)"
    echo -e "3) ${G}Docker Config${N} (In-box Docker host)"
    echo -e "4) ${G}Install Preset Box${N} (docker/tailscale/alpine)"
    echo -e "b) Back to Main Menu"
    echo

    read -p "Select [1-4]: " l_opt
    case $l_opt in
        1)
            echo -e "\n${B}Tailscale (rootd-fs)${N}"
            echo -e "1) Start Daemon (Foreground)"
            echo -e "2) Tailscale Up (Auth)"
            echo -e "3) Status & IP"
            echo -e "4) Tailscale Down"
            read -p "Option: " ts_opt
            case $ts_opt in
                1) 
                   echo -e "${Y}Daemon running in foreground. Open new tab for other commands.${N}"
                   read -p "Box name (default: tailscale): " box
                   box=${box:-tailscale}
                   rootd tailscale "$box" daemon ;;
                2)
                   read -p "Box name (default: tailscale): " box
                   box=${box:-tailscale}
                   read -p "Hostname (default: termux): " host
                   host=${host:-termux}
                   rootd tailscale "$box" up --ssh --hostname="$host" ;;
                3)
                   read -p "Box name (default: tailscale): " box
                   box=${box:-tailscale}
                   rootd tailscale "$box" status
                   rootd tailscale "$box" ip ;;
                4)
                   read -p "Box name (default: tailscale): " box
                   box=${box:-tailscale}
                   rootd tailscale "$box" down ;;
            esac
            read -p "Press Enter to continue..."
            local_box_menu
            ;;
        2)
            echo -e "\n${B}SSH (rootd-fs)${N}"
            echo -e "1) Generate SSH Key in Box"
            echo -e "2) Connect to Host"
            read -p "Option: " ssh_opt
            case $ssh_opt in
                1)
                   read -p "Box name: " box
                   rootd ssh "$box" --keygen ;;
                2)
                   read -p "Box name: " box
                   read -p "Target (user@host): " target
                   rootd ssh "$box" -- "$target" ;;
            esac
            read -p "Press Enter to continue..."
            local_box_menu
            ;;
        3)
            echo -e "\n${B}Docker Host Config (rootd-fs)${N}"
            echo -e "1) Check Docker Capabilities"
            echo -e "2) Set Remote Docker Host"
            read -p "Option: " d_opt
            case $d_opt in
                1) 
                   read -p "Box name (default: docker): " box
                   box=${box:-docker}
                   rootd docker "$box" --check ;;
                2)
                   read -p "Box name (default: docker): " box
                   box=${box:-docker}
                   read -p "Host (e.g. ssh://user@100.x.y.z): " host
                   rootd docker "$box" --host "$host" ;;
            esac
            read -p "Press Enter to continue..."
            local_box_menu
            ;;
        4)
            read -p "Box name (tailscale/docker/alpine): " preset
            rootd install "$preset"
            read -p "Press Enter to continue..."
            local_box_menu
            ;;
        b) main_menu ;;
        *) local_box_menu ;;
    esac
}

main_menu
