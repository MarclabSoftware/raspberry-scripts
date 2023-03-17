#!/usr/bin/env bash

setCustomDNS() {
    echo -e "\n\nAdding custom DNS systemd-resolved configs"

    checkConfig "CONFIG_DNS_SRVS" || return 1
    checkConfig "CONFIG_DNS_FALLBACK_SRVS" || return 1
    checkConfig "CONFIG_DNS_DNSSEC" || return 1
    checkConfig "CONFIG_DNS_STUB_LISTENER" || return 1

    local resolved_confs_d="/etc/systemd/resolved.conf.d"
    local resolved_conf_f="$resolved_confs_d/custom_dns.conf"
    local resolv_conf_f="/etc/resolv.conf"
    local stub_resolv_f="/run/systemd/resolve/stub-resolv.conf"

    mkdir -p "$resolved_confs_d"

    echo \
        "# See resolved.conf(5) for details.
[Resolve]
DNS=$CONFIG_DNS_SRVS
FallbackDNS=$CONFIG_DNS_FALLBACK_SRVS
#Domains=
DNSSEC=$CONFIG_DNS_DNSSEC
#DNSOverTLS=no
#MulticastDNS=yes
#LLMNR=yes
#Cache=yes
#CacheFromLocalhost=no
DNSStubListener=$CONFIG_DNS_STUB_LISTENER
#DNSStubListenerExtra=
#ReadEtcHosts=yes
#ResolveUnicastSingleLabel=no" | tee "$resolved_conf_f" >/dev/null

    echo "DNS systemd-resolved configs added"

    if ! isVarEmpty "$CONFIG_DNS_UPLINK_MODE" && [ $CONFIG_DNS_UPLINK_MODE = true ]; then
        echo -e "\n\nSetting systemd-resolved in uplink mode"
        mv -f "$resolv_conf_f" "$resolv_conf_f.bak"
        echo "$resolv_conf_f backed up to $resolv_conf_f.bak"
        ln -s "$stub_resolv_f" "$resolv_conf_f"
        echo -e "\nsystemd-resolved in now configured in uplink mode"
        systemctl restart systemd-resolved
    fi
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
    setCustomDNS
    exit $?
fi
