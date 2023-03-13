#!/usr/bin/env bash

journal_limit() {
    # Defaults
    local config_journal_system_max_default="250M"
    local config_journal_file_max_default="50M"
    # Dirs
    local journal_conf_d="/etc/systemd/journald.conf.d"

    # Apply default if conf is not found
    local system_max="${CONFIG_JOURNAL_SYSTEM_MAX:=$config_journal_system_max_default}"
    local file_max="${CONFIG_JOURNAL_FILE_MAX:=$config_journal_file_max_default}"

    echo -e "\n\nLimit journal size"
    mkdir -p "${journal_conf_d}"
    echo "Using SystemMaxUse=${system_max} | SystemMaxFileSize=${file_max}"
    echo -e "[Journal]\nSystemMaxUse=${system_max}\nSystemMaxFileSize=${file_max}" | tee "${journal_conf_d}/size.conf" >/dev/null
    echo "New conf file is located at ${journal_conf_d}/size.conf"
    echo "Journal size limited"
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
    journal_limit
    exit 0
fi
