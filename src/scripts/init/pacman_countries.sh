#!/usr/bin/env bash

setPacmanCountries() {
    # Defaults
    local countries_default="Global"
    # Apply default if conf is not found
    local coutries="${CONFIG_PACMAN_MIRRORS_COUNTRIES:=$countries_default}"

    echo -e "\n\nUpdating pacman mirrors"

    if ! checkCommand "pacman-mirrors"; then
        echo "Cannot continue"
        return 1 # Error
    fi

    echo "Using $coutries as mirrors"
    pacman-mirrors --country "$coutries"
    echo "Pacman mirrors updated"

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
    setPacmanCountries
    exit $?
fi
