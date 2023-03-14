#!/usr/bin/env bash

optimizeNetwork() {
    local systctld_network_conf_f="/etc/sysctl.d/21-network_optimizations.conf"

    echo -e "\n\nAdding network confs to $systctld_network_conf_f"
    echo \
        "# Improve Network performance
# This sets the max OS receive buffer size for all types of connections.
net.core.rmem_max = 8388608
# This sets the max OS send buffer size for all types of connections.
net.core.wmem_max = 8388608" | tee "$systctld_network_conf_f" >/dev/null
    echo "Network optimizations done"
    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "${SCRIPT_D}/utils.sh"
    if ! checkSU; then
        exit 1
    fi
    optimizeNetwork
    exit $?
fi
