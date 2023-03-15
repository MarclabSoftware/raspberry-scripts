#!/usr/bin/env bash

dockerLogin() {
    echo -e "\n\nDocker login"

    sudo -u "$CONFIG_USER" docker login
    if ! checkCommand "docker"; then
        echo "docker command missing, cannot proceed"
        return 1
    fi

    echo "Please prepare docker hub user and password"
    paktc

    if checkSU >/dev/null; then
        if isVarEmpty "$CONFIG_USER"; then
            echo -e "\nMissing CONFIG_USER, please enter the normal user name and press enter\n"
            read -r
            CONFIG_USER="$REPLY"
        fi

        if ! isNormalUser "$CONFIG_USER"; then
            echo -e "\nCONFIG_USER problem, it must be set, it must be a normal user, it must exists"
            return 1
        fi
        sudo -u "$CONFIG_USER" docker login
    else
        docker login
    fi

    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "$SCRIPT_D/utils.sh"
    . "$SCRIPT_D/init.conf"
    dockerLogin
    exit $?
fi
