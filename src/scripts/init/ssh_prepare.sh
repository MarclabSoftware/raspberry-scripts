#!/usr/bin/env bash

prepareSSH() {
    echo -e "\n\nAdding .ssh folders and basic files"

    if isVarEmpty "$CONFIG_USER"; then
        echo -e "\nMissing CONFIG_USER, please enter the normal user name and press enter\n"
        read -r
        CONFIG_USER="$REPLY"
    fi

    if ! isNormalUser "$CONFIG_USER"; then
        echo -e "\nCONFIG_USER problem, it must be set, it must be a normal user, it must exists"
        return 1
    fi

    if isVarEmpty "$HOME_USER_D"; then
        HOME_USER_D=$(sudo -u "$CONFIG_USER" sh -c 'echo $HOME')
    fi

    if isVarEmpty "$HOME_ROOT_D"; then
        HOME_ROOT_D=$(sudo -u root sh -c 'echo $HOME')
    fi

    local ssh_root_d="$HOME_ROOT_D/.ssh"
    local ssh_user_d="$HOME_USER_D/.ssh"
    export SSH_AUTH_KEYS_ROOT_F="$ssh_root_d/authorized_keys"
    export SSH_AUTH_KEYS_USER_F="$ssh_user_d/authorized_keys"
    export SSH_KNOWN_HOSTS_ROOT_F="$ssh_root_d/known_hosts"
    export SSH_KNOWN_HOSTS_USER_F="$ssh_user_d/known_hosts"

    mkdir -p "$ssh_root_d"
    touch "$SSH_AUTH_KEYS_ROOT_F" "$SSH_KNOWN_HOSTS_ROOT_F"
    sudo -u "$CONFIG_USER" mkdir -p "$ssh_user_d"
    sudo -u "$CONFIG_USER" touch "$SSH_AUTH_KEYS_USER_F" "$SSH_KNOWN_HOSTS_USER_F"
    chmod 700 "$ssh_root_d" "$ssh_user_d"
    chmod 600 "$SSH_AUTH_KEYS_ROOT_F" "$SSH_KNOWN_HOSTS_ROOT_F" "$SSH_AUTH_KEYS_USER_F" "$SSH_KNOWN_HOSTS_USER_F"
    echo ".ssh folders and basic files added"
    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "$SCRIPT_D/init.conf"
    . "$SCRIPT_D/utils.sh"
    if ! checkSU; then
        exit 1
    fi
    prepareSSH
    exit $?
fi
