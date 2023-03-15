#!/usr/bin/env bash

addUserToGroups() {
    echo -e "\n\nAdding user to groups"

    if isVarEmpty CONFIG_USER; then
        echo >&2 "CONFIG_USER unset or empty, cannot continue"
        return 1
    fi

    if isVarEmpty CONFIG_USER_GROUPS_TO_ADD; then
        echo >&2 "CONFIG_USER_GROUPS_TO_ADD unset or empty, cannot continue"
        return 1
    fi

    echo -e "\n\nAdding $CONFIG_USER to $CONFIG_USER_GROUPS_TO_ADD groups"
    usermod -aG "$CONFIG_USER_GROUPS_TO_ADD" "$CONFIG_USER"
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
    addUserToGroups
    exit $?
fi
