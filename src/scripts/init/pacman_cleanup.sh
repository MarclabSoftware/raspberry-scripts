#!/usr/bin/env bash

pacmanCleanup() {
    echo -e "\n\nRemoving orphaned packages"
    pacman -Qtdq | pacman --noconfirm -Rns - 2>/dev/null
    echo "Orphaned packages removed"

    echo -e "\n\nRemoving unneded cached packages"

    if ! checkCommand "paccache"; then
        echo "Installing now, please confirm"
        pacman -Syy
        pacman -S --needed --noconfirm pacman-contrib
        if ! checkCommand "paccache"; then
            echo "Cannot clean"
            return 1
        fi
    fi

    paccache -rk1
    paccache -ruk0
    echo "Unneded cached packages removed"

    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "$SCRIPT_D/utils.sh"
    checkSU || exit 1
    pacmanCleanup
    exit $?
fi
