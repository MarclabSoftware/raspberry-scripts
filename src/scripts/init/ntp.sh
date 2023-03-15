#!/usr/bin/env bash

customNtp() {
    echo -e "\n\nTimesyncd setup"

    if ! systemctl is-active --quiet systemd-timesyncd; then
        echo "systemd-timesyncd is not running, maybe this OS is not using it for timesync, config not applied"
        return 1
    fi

    local timesyncd_confs_d="/etc/systemd/timesyncd.conf.d"
    local timesyncd_conf_f="$timesyncd_confs_d/custom.conf"
    local ntp_srvs_default="time.cloudflare.com"
    local ntp_fallback_srvs_default="pool.ntp.org"

    if isVarEmpty "$CONFIG_NTP_SERVERS"; then
        echo "CONFIG_NTP_SERVERS not configured, using deafult"
        : "${CONFIG_NTP_SERVERS:=$ntp_srvs_default}"
    fi

    if isVarEmpty "$CONFIG_NTP_FALLBACK_SERVERS"; then
        echo "CONFIG_NTP_FALLBACK_SERVERS not configured, using deafult"
        : "${CONFIG_NTP_FALLBACK_SERVERS:=$ntp_fallback_srvs_default}"
    fi

    echo "NTP server: $CONFIG_NTP_SERVERS"
    echo "NTP fallback server: $CONFIG_NTP_FALLBACK_SERVERS"
    mkdir -p "$timesyncd_confs_d"
    echo \
        "[Time]
NTP=$CONFIG_NTP_SERVERS
FallbackNTP=$CONFIG_NTP_FALLBACK_SERVERS" | tee "$timesyncd_conf_f" >/dev/null
    systemctl restart systemd-timesyncd
    echo "Timesyncd setup done"

    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "$SCRIPT_D/init.conf"
    . "$SCRIPT_D/utils.sh"
    if ! checkSU; then
        exit 1
    fi
    customNtp
    exit $?
fi
