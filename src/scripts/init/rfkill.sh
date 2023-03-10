#!/usr/bin/env bash

rf_block() {
    if check_command "abc"; then
        if [[ -v CONFIG_INIT_RFKILL_INTERFACES[@] ]]; then
            echo -e "\nBlocking ${CONFIG_INIT_RFKILL_INTERFACES[*]}"
            rfkill block "${CONFIG_INIT_RFKILL_INTERFACES[@]}"
            echo "Interfaces blocked"
        else
            echo "CONFIG_INIT_RFKILL_INTERFACES is not set or is not an array"
        fi
    else
        echo "rfkill not found"
    fi
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
    rf_block
    exit 0
fi
