#!/usr/bin/env bash

enableTrim() {

    echo -e "\n\nConfiguring trim for SSD"
    local trim_rules_f="/etc/udev/rules.d/21-ssd_trim.rules"

    checkConfig "CONFIG_SSD_TRIM_VENDOR" || return 1
    checkConfig "CONFIG_SSD_TRIM_PRODUCT" || return 1

    echo -e "Setting trim conf to $trim_rules_f"
    echo "Configured vendor: $CONFIG_SSD_TRIM_VENDOR | product: $CONFIG_SSD_TRIM_PRODUCT"

    echo -e 'ACTION=="add|change", ATTRS{idVendor}=="'"$CONFIG_SSD_TRIM_VENDOR"'", ATTRS{idProduct}=="'"$CONFIG_SSD_TRIM_PRODUCT"'", SUBSYSTEM=="scsi_disk", ATTR{provisioning_mode}="unmap"' | tee "$trim_rules_f" >/dev/null
    udevadm control --reload-rules
    udevadm trigger
    fstrim -av
    systemctl enable --now fstrim.timer
    echo "Trim enabled"
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
    enableTrim
    exit $?
fi
