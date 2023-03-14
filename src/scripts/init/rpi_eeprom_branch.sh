#!/usr/bin/env bash

changeEepromBranch() {
    # Defaults
    local branch_default="stable"
    # Dirs
    local eeprom_update_f="/etc/default/rpi-eeprom-update"
    # Apply default if conf is not found
    local branch="${CONFIG_RPI_EEPROM_UPDATE_BRANCH:=$branch_default}"

    echo -e "\n\nChanging Rpi EEPROM update channel to '${branch}'"

    if [ ! -f "${eeprom_update_f}" ]; then
        echo "Cannot change branch, ${eeprom_update_f} file is missing"
        return 1
    fi

    sed -i 's/FIRMWARE_RELEASE_STATUS=".*"/FIRMWARE_RELEASE_STATUS="'"${branch}"'"/g' "${eeprom_update_f}"
    echo "Rpi EEPROM update channel changed"
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
    changeEepromBranch
    exit $?
fi
