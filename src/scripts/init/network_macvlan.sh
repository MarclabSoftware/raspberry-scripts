#!/usr/bin/env bash

enableMacVlan() {
    echo -e "\n\nMACVLAN host <-> docker bridge setup"

    if isVarEmpty "$CONFIG_NETWORK_MACVLAN_NAME"; then
        echo "Missing CONFIG_NETWORK_MACVLAN_NAME, cannot proceed"
        return 1
    fi

    if isVarEmpty "$CONFIG_NETWORK_MACVLAN_PARENT"; then
        echo "Missing CONFIG_NETWORK_MACVLAN_PARENT, cannot proceed"
        return 1
    fi

    if isVarEmpty "$CONFIG_NETWORK_MACVLAN_STATIC_IP"; then
        echo "Missing CONFIG_NETWORK_MACVLAN_STATIC_IP, cannot proceed"
        return 1
    fi

    if isVarEmpty "$CONFIG_NETWORK_MACVLAN_RANGE"; then
        echo "Missing CONFIG_NETWORK_MACVLAN_RANGE, cannot proceed"
        return 1
    fi

    local systemd_network_d="/etc/systemd/network"
    local dhcpcd_conf_f="/etc/dhcpcd.conf"

    echo \
        "[Match]
Name=$CONFIG_NETWORK_MACVLAN_PARENT

[Network]
MACVLAN=$CONFIG_NETWORK_MACVLAN_NAME" | tee "$systemd_network_d/$CONFIG_NETWORK_MACVLAN_PARENT.network" >/dev/null

    echo \
        "[NetDev]
Name=$CONFIG_NETWORK_MACVLAN_NAME
Kind=macvlan

[MACVLAN]
Mode=bridge" | tee "$systemd_network_d/$CONFIG_NETWORK_MACVLAN_NAME.netdev" >/dev/null

    echo \
        "[Match]
Name=$CONFIG_NETWORK_MACVLAN_NAME

[Route]
Destination=$CONFIG_NETWORK_MACVLAN_RANGE

[Network]
DHCP=no
Address=$CONFIG_NETWORK_MACVLAN_STATIC_IP/32
IPForward=yes
ConfigureWithoutCarrier=yes" | tee "$systemd_network_d/$CONFIG_NETWORK_MACVLAN_NAME.network" >/dev/null

    echo -e "# Custom config for MACVLAN\ndenyinterfaces $CONFIG_NETWORK_MACVLAN_NAME" | tee -a "$dhcpcd_conf_f" >/dev/null

    echo -e "[Service]\nExecStart=\nExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any" | SYSTEMD_EDITOR="tee" systemctl edit systemd-networkd-wait-online.service

    if ! isVarEmpty "$CONFIG_NETWORK_MACVLAN_IPV6_DISABLE" && [ "$CONFIG_NETWORK_MACVLAN_IPV6_DISABLE" = true ]; then
        echo -e "LinkLocalAddressing=no\nIPv6AcceptRA=no" | tee -a "$systemd_network_d/$CONFIG_NETWORK_MACVLAN_PARENT.network" >/dev/null
        echo -e "LinkLocalAddressing=no\nIPv6AcceptRA=no" | tee -a "$systemd_network_d/$CONFIG_NETWORK_MACVLAN_NAME.network" >/dev/null
    fi

    systemctl daemon-reload
    echo -e "\nMACVLAN setup done"
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
    enableMacVlan
    exit $?
fi
