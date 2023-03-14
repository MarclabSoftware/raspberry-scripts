#!/usr/bin/env bash

# TODO: find a better place for this, add safety checks
# $1: config string
# $2: conf file
# $3: conf value
addIfNotFound() {
    if grep -q "${1}" "${2}"; then
        sudo sed -i "s/.*${1}.*/${1}=${3}/" "${2}"
    else
        echo "${1}=${3}" | sudo tee -a "${2}" >/dev/null
    fi
}

goFaster() {
    # Defaults
    local config_ov_default=0
    local config_arm_freq_default=1500
    local config_gpu_freq_default=500

    # Apply default if conf is not found
    local ov="${CONFIG_RPI_OVERCLOCK_OVER_VOLTAGE:=$config_ov_default}"
    local arm_freq="${CONFIG_RPI_OVERCLOCK_ARM_FREQ:=$config_arm_freq_default}"
    local gpu_freq="${CONFIG_RPI_OVERCLOCK_GPU_FREQ:=$config_gpu_freq_default}"

    # Dirs
    local boot_conf_f="/boot/config.txt"

    echo -e "\n\nSetting overclock"

    if [ ! -f "${boot_conf_f}" ]; then
        echo "${boot_conf_f} file not found, cannot apply overclock."
        return 1
    fi

    addIfNotFound "over_voltage" "${boot_conf_f}" "${ov}"
    addIfNotFound "arm_freq" "${boot_conf_f}" "${arm_freq}"
    addIfNotFound "gpu_freq" "${boot_conf_f}" "${gpu_freq}"
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
    goFaster
    exit $?
fi
