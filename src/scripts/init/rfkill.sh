#!/usr/bin/env bash

rf_block() {
    # Config var name + indirection
    local config_interfaces_name="CONFIG_RFKILL_INTERFACES"
    declare -n config_interfaces_str="${config_interfaces_name}"

    if ! check_command "rfkill"; then
        echo "rfkill not found"
        return 1 # Error
    fi

    declare -a config_interfaces_arr

    if [ -z ${config_interfaces_str+x} ]; then
        echo "${config_interfaces_name} unset or empty"
        echo -e "\nWireless interfaces found:\n"
        rfkill list
        echo -e "\nPlease input one or more space separated interfaces to block, then press enter to confirm"
        read -r -a config_interfaces_arr
        echo
    else
        readarray -td, config_interfaces_arr <<<"$config_interfaces_str,"
        unset 'config_interfaces_arr[-1]'
    fi
    echo -e "Interfaces to block: ${config_interfaces_arr[*]}"
    rfkill block "${config_interfaces_arr[@]}"
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
    rf_block
    exit 0
fi
