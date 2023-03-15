#!/usr/bin/env bash

enableRouting() {
    local systctld_network_conf_f="/etc/sysctl.d/21-network_routing.conf"
    echo -e "\n\nAdding network confs to $systctld_network_conf_f"
    echo "net.ipv4.ip_forward = 1" | tee "$systctld_network_conf_f" >/dev/null
    echo "Routing enabled"
    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "$SCRIPT_D/utils.sh"
    checkSU || exit 1
    enableRouting
    exit $?
fi
