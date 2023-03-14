#!/usr/bin/env bash

installPacmanPackages() {
    declare -a config_pkgs_arr
    echo -e "\n\nInstalling new packages"

    if isVarEmpty "$CONFIG_PACMAN_PACKAGES"; then
        echo "CONFIG_PACMAN_PACKAGES unset or empty"
        echo -e "\nPlease input one or more space separated pacman packages to install, then press enter to confirm"
        read -r -a config_pkgs_arr
        echo
    else
        readarray -td, config_pkgs_arr <<<"$CONFIG_PACMAN_PACKAGES,"
        unset 'config_pkgs_arr[-1]'
    fi

    echo "New packages to install: ${config_pkgs_arr[*]}"
    # FIXME: noconfirm doesn't work with packages like linux-rpi4-mainline due to incompatibilites with installed packages
    pacman -Syy
    pacman -S --needed "${config_pkgs_arr[@]}"
    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "${SCRIPT_D}/init.conf"
    . "${SCRIPT_D}/utils.sh"
    if ! checkSU; then
        exit 1
    fi
    installPacmanPackages
    exit $?
fi
