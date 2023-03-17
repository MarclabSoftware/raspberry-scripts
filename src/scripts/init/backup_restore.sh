#!/usr/bin/env bash

restoreBackup() {
    echo -e "\n\nRestoring backup"

    checkConfig "CONFIG_BACKUP_FILE_PATH" || return 1

    if [ ! -f "$CONFIG_BACKUP_FILE_PATH" ]; then
        echo -e "\nCannot find $CONFIG_BACKUP_FILE_PATH, please check"
        return 1
    else
        tar --same-owner -xf "$CONFIG_BACKUP_FILE_PATH" -C /
    fi

    echo "Backup restored"
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
    restoreBackup
    exit $?
fi
