#!/usr/bin/env bash

setSwappiness() {
    # Defaults
    local swappiness_default=60
    # Dirs
    local swappiness_conf_f="/etc/sysctl.d/swappiness.conf"
    # Apply default if conf is not found
    local swappiness="${CONFIG_RAM_SWAPPINESS_VALUE:=$swappiness_default}"

    echo -e "\n\nSetting custom swappiness"
    echo "New swappiness value: $swappiness"
    echo "vm.swappiness=$swappiness" | tee "$swappiness_conf_f" >/dev/null
    echo "Custom swappiness set, it will be applied from the next reboot"
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
    setSwappiness
    exit $?
fi
