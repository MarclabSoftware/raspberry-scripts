#!/usr/bin/env bash

disableIpv6() {

    local boot_cmdline_f="/boot/cmdline.txt"
    local dhcpcd_conf_f="/etc/dhcpcd.conf"
    local systctld_network_conf_f="/etc/sysctl.d/21-network_ipv6_disable.conf"

    echo -e "\n\nDisabling IPv6"

    if [ ! -f "$boot_cmdline_f" ]; then
        echo "Missing $boot_cmdline_f file, cannot proceed"
        return 1
    fi

    if [ ! -f "$dhcpcd_conf_f" ]; then
        echo "Missing $dhcpcd_conf_f file, cannot proceed"
        return 1
    fi

    cp -a "$boot_cmdline_f" "$boot_cmdline_f.bak"
    echo "Boot cmdline file backed up at $boot_cmdline_f.bak"
    sed -i 's/$/ ipv6.disable_ipv6=1/g' "$boot_cmdline_f"

    echo -e "net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1" | tee "$systctld_network_conf_f" >/dev/null

    echo -e "ipv4only\nnoipv6rs\nnoipv6" | tee -a "$dhcpcd_conf_f" >/dev/null

    echo "IPv6 disabled"
    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "$SCRIPT_D/utils.sh"
    if ! checkSU; then
        exit 1
    fi
    disableIpv6
    exit $?
fi
