#!/usr/bin/env bash

updateEeprom() {
    echo -e "\n\nChecking for Rpi EEPROM updates"

    if ! checkCommand "rpi-eeprom-update"; then
        echo "Cannot update"
        return 1
    fi
    rpi-eeprom-update -d -a
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
    updateEeprom
    exit $?
fi
