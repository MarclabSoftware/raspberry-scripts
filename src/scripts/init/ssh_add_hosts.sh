#!/usr/bin/env bash

addSSHHosts() {
    echo -e "\n\nAdding SSH useful known hosts"

    if ! checkCommand "ssh-keyscan"; then
        echo >&2 "Cannot continue"
        return 1
    fi

    declare -a config_hosts_arr

    if isVarEmpty "$CONFIG_SSH_HOSTS"; then
        echo "CONFIG_SSH_HOSTS unset or empty"
        echo -e "\nPlease input one or more space separated host, then press enter to confirm"
        echo -e "EG: github.com gitlab.com\n"
        read -r -a config_hosts_arr
        echo
    else
        readarray -td, config_hosts_arr <<<"$CONFIG_SSH_HOSTS,"
        unset 'config_hosts_arr[-1]'
    fi

    echo "Hosts to add: ${config_hosts_arr[*]}"

    ssh-keyscan "${config_hosts_arr[@]}" | tee -a "$SSH_KNOWN_HOSTS_ROOT_F" >/dev/null
    tee -a "$SSH_KNOWN_HOSTS_USER_F" <"$SSH_KNOWN_HOSTS_ROOT_F"
    echo "SSH useful known hosts added"
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
    addSSHHosts
    exit $?
fi
