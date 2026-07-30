#!/usr/bin/env bash
# Quick-start menu for termuxrd-cloud & rootd-fs

G='\033[32m'; Y='\033[33m'; R='\033[31m'; C='\033[36m'; B='\033[1m'; N='\033[0m'

# Global OCI Profile
OCI_PROFILE="DEFAULT"
SSH_CONFIG="$HOME/.ssh/config"

main_menu() {
    clear
    echo -e "${B}TermuxRD-Cloud & rootd-fs Manager${N}"
    echo -e "------------------------------------"
    echo -e "Active OCI Profile: ${Y}${OCI_PROFILE}${N}"
    echo -e "------------------------------------"
    echo -e "1) ${C}Setup Termux${N} (Initial Android setup)"
    echo -e "2) ${C}Install OCI CLI${N} (Oracle Cloud management)"
    echo -e "3) ${C}Import OCI Profile from .env${N}"
    echo -e "4) ${C}Hunt ARM Capacity${N} (Find Always Free VMs)"
    echo -e "5) ${C}Cloud VM Connection${N} (SSH & Config Manager)"
    echo -e "6) ${C}Local Box Tooling${N} (Tailscale & SSH via rootd-fs)"
    echo -e "7) ${C}Healthcheck${N} (Diagnose setup)"
    echo -e "8) ${C}AI Agent Manager${N} (Deploy AI to VM)"
    echo -e "d) ${Y}Debug OCI Profile${N}"
    echo -e "p) ${Y}Switch OCI Profile${N}"
    echo -e "q) Exit"
    echo

    read -p "Select [1-8/d/p/q]: " pilihan

    case $pilihan in
        1) bash scripts/termux-setup.sh ;;
        2) bash scripts/termux-oci-cli.sh ;;
        3)
            read -p "Path to .env file (e.g. ~/.env): " env_path
            read -p "New Profile Name: " prof_name
            if [ -n "$env_path" ] && [ -n "$prof_name" ]; then
                bash scripts/oci-env-to-config.sh "$env_path" "$prof_name"
                read -p "Press Enter to continue..."
            fi
            main_menu
            ;;
        4) 
            bash scripts/oci-grab-arm.sh --profile "$OCI_PROFILE"
            read -p "Press Enter to continue..."
            main_menu
            ;;
        5) cloud_vm_menu ;;
        6) local_box_menu ;;
        7) bash scripts/healthcheck.sh ; read -p "Press Enter to continue..." ; main_menu ;;
        8) ai_manager_menu ;;
        d)
            echo -e "\n${B}Debugging OCI Profile: ${Y}${OCI_PROFILE}${N}"
            echo -e "Testing connectivity and permissions..."
            oci iam region list --profile "$OCI_PROFILE" --output table || {
                echo -e "\n${R}OCI CLI Test Failed!${N}"
                echo -e "Check your ~/.oci/config and API key."
            }
            read -p "Press Enter to continue..."
            main_menu
            ;;
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
    echo -e "${B}Cloud VM & SSH Config Manager${N}"
    echo -e "------------------------------------"
    echo -e "Active OCI Profile: ${Y}${OCI_PROFILE}${N}"
    echo -e "------------------------------------"
    echo -e "1) List OCI Instances"
    echo -e "2) Setup SSH Key for Cloud"
    echo -e "3) Connect to VM (Manual SSH)"
    echo -e "4) ${G}Manage SSH Config (~/.ssh/config)${N}"
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
        4) ssh_config_menu ;;
        *) main_menu ;;
    esac
}

ssh_config_menu() {
    clear
    echo -e "${B}SSH Config Manager (~/.ssh/config)${N}"
    echo -e "------------------------------------"
    if [ -f "$SSH_CONFIG" ]; then
        echo -e "Current Configured Hosts:"
        grep -i "^Host " "$SSH_CONFIG" | awk '{print "  - " $2}'
    else
        echo -e "${Y}No SSH config file found at $SSH_CONFIG${N}"
    fi
    echo -e "------------------------------------"
    echo -e "1) Add New Host Entry"
    echo -e "2) View Full Config"
    echo -e "3) Delete Host Entry (Manual Edit)"
    echo -e "b) Back"
    echo
    read -p "Option: " s_opt
    case $s_opt in
        1)
            echo -e "\n${B}Add New SSH Host Entry${N}"
            read -p "Alias Name (e.g. oci-vm): " alias
            read -p "HostName (IP or FQDN): " hostname
            read -p "User (default: ubuntu): " user
            user=${user:-ubuntu}
            read -p "IdentityFile (default: ~/.ssh/id_ed25519): " idfile
            idfile=${idfile:-~/.ssh/id_ed25519}
            
            mkdir -p "$HOME/.ssh"
            cat >> "$SSH_CONFIG" <<EOF

Host $alias
    HostName $hostname
    User $user
    IdentityFile $idfile
    ServerAliveInterval 30
    ServerAliveCountMax 4
EOF
            echo -e "${G}Added $alias to $SSH_CONFIG${N}"
            sleep 2
            ssh_config_menu
            ;;
        2)
            if [ -f "$SSH_CONFIG" ]; then
                clear
                echo -e "${B}Full SSH Config ($SSH_CONFIG):${N}"
                cat "$SSH_CONFIG"
                read -p "Press Enter to continue..."
            fi
            ssh_config_menu
            ;;
        3)
            echo -e "${Y}Opening $SSH_CONFIG in editor...${N}"
            nano "$SSH_CONFIG" || vi "$SSH_CONFIG"
            ssh_config_menu
            ;;
        *) cloud_vm_menu ;;
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

ai_manager_menu() {
    clear
    echo -e "${B}AI Agent Manager (Ollama + Open WebUI)${N}"
    echo -e "---------------------------------------"
    echo -e "Target VM: ${Y}${DOCKER_HOST:-Not Set}${N}"
    echo -e "---------------------------------------"
    echo -e "1) ${G}Deploy AI Stack${N} (Ollama + WebUI)"
    echo -e "2) ${C}Pull New Model${N} (Llama3, DeepSeek, etc)"
    echo -e "3) ${C}Check AI Status${N} (Docker PS)"
    echo -e "4) Stop AI Stack"
    echo -e "b) Back to Main Menu"
    echo
    read -p "Option: " ai_opt
    case $ai_opt in
        1) bash scripts/deploy-ai.sh ;;
        2)
            read -p "Enter model name (e.g. llama3.1:8b): " m_name
            rootd sh docker -- docker exec -it ollama ollama pull "$m_name" ;;
        3) rootd sh docker -- docker ps | grep -E "ollama|open-webui" ;;
        4) rootd sh docker -- docker compose -f ~/ai-stack/docker-compose.yaml down ;;
        *) main_menu ;;
    esac
    read -p "Press Enter to continue..."
    ai_manager_menu
}
