#!/usr/bin/env bash

enablePasswordlessSudo() {
    echo -e "\n\nSetting sudo without password"

    if isVarEmpty "$CONFIG_USER"; then
        echo -e "\nMissing CONFIG_USER, please enter the normal user name and press enter\n"
        read -r
        CONFIG_USER="$REPLY"
    fi

    if ! isNormalUser "$CONFIG_USER"; then
        echo -e "\nCONFIG_USER problem, it must be set, it must be a normal user, it must exists"
        return 1
    fi

    echo -e "New super-uber-user: $CONFIG_USER"

    local sudoers_f="/etc/sudoers.d/99-$CONFIG_USER"

    if [ -f "$sudoers_f" ]; then
        echo "$sudoers_f file already exists, please check"
        return 1
    fi

    echo "$CONFIG_USER ALL=(ALL) NOPASSWD: ALL" | tee "$sudoers_f" >/dev/null
    chmod 750 "$sudoers_f"
    echo "$CONFIG_USER can run sudo without password from the next boot."
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
    enablePasswordlessSudo
    exit $?
fi
