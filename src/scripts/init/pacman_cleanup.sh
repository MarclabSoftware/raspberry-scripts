#!/usr/bin/env bash

pacmanCleanup() {
    echo -e "\n\nRemoving orphaned packages"
    pacman -Qtdq | pacman --noconfirm -Rns - 2>/dev/null
    echo "Orphaned packages removed"

    if ! checkCommand "paccache"; then
        echo "paccache not found, installing now, please confirm"
        pacman -Syy
        pacman -S --needed --noconfirm pacman-contrib
        if ! checkCommand "paccache"; then
            echo "paccache not installed, cannot clean"
            return 1
        fi
    fi

    echo -e "\n\nRemoving unneded cached packages"
    paccache -rk1
    paccache -ruk0
    echo "Unneded cached packages removed"

    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "${sourced}" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "${SCRIPT_D}/init.conf"
    . "${SCRIPT_D}/utils.sh"
    if ! checkSU; then
        exit 1
    fi
    pacmanCleanup
    exit $?
fi
