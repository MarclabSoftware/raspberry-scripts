#!/usr/bin/env bash

setPacmanColors() {
    local pacman_conf_f="/etc/pacman.conf"
    echo -e "\n\nEnabling Pacman colored output"
    cp -af "${pacman_conf_f}" "${pacman_conf_f}.bak"
    echo "Pacman config file backed up at ${pacman_conf_f}.bak"
    sed -i 's/#Color/Color\nILoveCandy/g' "${pacman_conf_f}"
    echo -e "Pacman colored output enabled"
    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "${sourced}" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "${SCRIPT_D}/utils.sh"
    if ! checkSU; then
        exit 1
    fi
    setPacmanColors
    exit $?
fi
