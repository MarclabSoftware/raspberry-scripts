#!/usr/bin/env bash

createCustomDockerBridgeNetwork() {
    echo -e "\n\nCreating Docker custom bridge network"

    local docker_group="docker"

    if ! checkCommand "docker"; then
        echo >&2 "docker command missing, cannot proceed"
        return 1
    fi

    if isVarEmpty "$CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME"; then
        echo >&2 "Missing CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME, cannot proceed"
        return 1
    fi

    if ! checkSU 2>/dev/null && ! isMeInGroup "$docker_group"; then
        echo >&2 -e "\nCurrent user isn't in $docker_group group, cannot proceed"
        echo >&2 -e "\nAdd current user to $docker_group group or run this script as root"
        return 1
    fi

    docker network create "$CONFIG_DOCKER_NETWORK_CUSTOM_BRIDGE_NAME"
    echo "Docker custom bridge network created"
    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "$SCRIPT_D/utils.sh"
    . "$SCRIPT_D/init.conf"
    createCustomDockerBridgeNetwork
    exit $?
fi
