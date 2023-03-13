#!/usr/bin/env bash

setPacmanCountries() {
    # Defaults
    local countries_default="Global"
    # Apply default if conf is not found
    local coutries="${CONFIG_PACMAN_MIRRORS_COUNTRIES:=$countries_default}"

    if ! check_command "pacman-mirrors"; then
        echo "pacman-mirrors not found"
        return 1 # Error
    fi

    echo -e "\n\nUpdating pacman mirrors"
    echo "Using ${coutries} as mirrors"
    pacman-mirrors --country "${coutries}"
    echo "Pacman mirrors updated"

    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "${sourced}" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "${SCRIPT_D}/init.conf"
    . "${SCRIPT_D}/utils.sh"
    if ! check_su; then
        exit 1
    fi
    setPacmanCountries
    exit 0
fi
