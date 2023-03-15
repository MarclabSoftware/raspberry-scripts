#!/usr/bin/env bash

hardenSSH() {
    local ssh_conf_d="/etc/ssh"
    local sshd_conf_f="$ssh_conf_d/sshd_config"

    echo -e "\n\nHardening SSH\nhttps://www.ssh-audit.com/hardening_guides.html for details"

    rm -rf "$ssh_conf_d"/ssh_host_*
    ssh-keygen -t rsa -b 4096 -f "$ssh_conf_d/ssh_host_rsa_key" -N ""
    ssh-keygen -t ed25519 -f "$ssh_conf_d/ssh_host_ed25519_key" -N ""
    awk '$5 >= 3071' "$ssh_conf_d/moduli" >"$ssh_conf_d/moduli.safe"
    mv "$ssh_conf_d/moduli.safe" "$ssh_conf_d/moduli"

    if [ ! -f "$SCRIPT_D/sshd_config" ]; then
        echo "Missing $SCRIPT_D/sshd_config file"
        read -p "Do you want to paste it manually in editor? Y/N: " -n 1 -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            mv "$sshd_conf_f" "$sshd_conf_f.bak"
            echo "$sshd_conf_f backed up to $sshd_conf_f.bak"
            echo -e "\nPlease paste and save the new sshd_config"
            paktc
            nano "$sshd_conf_f"
        else
            echo "$sshd_conf_f file unchanged"
        fi
    else
        echo "$SCRIPT_D/sshd_config file found, using it to overwrite $sshd_conf_f"
        paktc
        mv "$sshd_conf_f" "$sshd_conf_f.bak"
        echo "$sshd_conf_f backed up to $sshd_conf_f.bak"
        tee "$sshd_conf_f" <"$SCRIPT_D/sshd_config"
    fi

    echo -e "\n\nPlease test the new sshd config before rebooting\nIf the command sudo sshd -t has no output the config is ok, otherways check it"
    paktc
    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "$SCRIPT_D/init.conf"
    . "$SCRIPT_D/utils.sh"
    checkSU || exit 1
    hardenSSH
    exit $?
fi
