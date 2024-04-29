#!/usr/bin/env bash

dockerLogin() {
    echo -e "\n\nDocker login"

    local docker_group="docker"

    if ! checkCommand "docker"; then
        echo >&2 "docker command missing, cannot proceed"
        return 1
    fi

    echo "Please prepare docker hub user and password"
    paktc

    if ! checkSU 2>/dev/null; then
        if ! isMeInGroup "$docker_group"; then
            echo >&2 -e "\nCurrent user isn't in $docker_group group, cannot proceed"
            return 1
        fi
        docker login
        return 0
    fi

    if isVarEmpty "$CONFIG_USER"; then
        echo -e "\nMissing CONFIG_USER, please enter the normal user name and press enter\n"
        read -r
        CONFIG_USER="$REPLY"
    fi

    if ! isNormalUser "$CONFIG_USER"; then
        echo >&2 -e "\nCONFIG_USER problem, it must be set, it must be a normal user, it must exists"
        return 1
    fi

    if ! isUserInGroup "$CONFIG_USER" "$docker_group"; then
        echo >&2 -e "\nCONFIG_USER found, $CONFIG_USER isn't in $docker_group group"
        read -p "Do you want to add $CONFIG_USER to $docker_group group? Y/N: " -n 1 -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            usermod -aG "$docker_group" "$CONFIG_USER"
        else
            echo >&2 "Cannot proceed"
            return 1
        fi
    fi
    sudo -u "$CONFIG_USER" docker login
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
