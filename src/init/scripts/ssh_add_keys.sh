#!/usr/bin/env bash

addSSHKeys() {
    echo -e "\n\nAdding SSH keys"

    if isVarEmpty "$CONFIG_SSH_KEY_USER"; then
        echo "Missing CONFIG_SSH_KEY_USER"
        echo -e "Please insert public SSH key for $CONFIG_USER and press Enter\nEG: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB8Ht8Z3j6yDWPBHQtOp/R9rjWvfMYo3MSA/K6q8D86r\nLeave empty to skip\n"
        read -r
        CONFIG_SSH_KEY_USER="$REPLY"
    fi

    if isVarEmpty "$CONFIG_SSH_KEY_USER"; then
        echo "Empty key for $CONFIG_USER, skipping"
    else
        echo "$CONFIG_SSH_KEY_USER" | tee -a "$SSH_AUTH_KEYS_USER_F" >/dev/null
    fi

    if isVarEmpty "$CONFIG_SSH_KEY_ROOT"; then
        echo "Missing CONFIG_SSH_KEY_ROOT"
        echo -e "Please insert public SSH key for root and press Enter\nEG: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB8Ht8Z3j6yDWPBHQtOp/R9rjWvfMYo3MSA/K6q8D86r\nLeave empty to skip\n"
        read -r
        CONFIG_SSH_KEY_ROOT="$REPLY"
    fi

    if isVarEmpty "$CONFIG_SSH_KEY_ROOT"; then
        echo "Empty key for root, skipping"
    else
        echo "$CONFIG_SSH_KEY_ROOT" | tee -a "$SSH_AUTH_KEYS_ROOT_F" >/dev/null
    fi

    echo "SSH keys added"
    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "$SCRIPT_D/init.conf"
    . "$SCRIPT_D/utils.sh"
    . "$SCRIPT_D/ssh_prepare.sh"
    checkSU || exit 1
    prepareSSH || exit 1
    addSSHKeys
    exit $?
fi
