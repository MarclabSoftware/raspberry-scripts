#!/usr/bin/env bash

createDockerMacvlanNetwork() {
    echo -e "\n\nCreating Docker MACVLAN network"

    local docker_group="docker"

    if ! checkCommand "docker"; then
        echo >&2 "docker command missing, cannot proceed"
        return 1
    fi

    checkConfig "CONFIG_NETWORK_MACVLAN_SUBNET" && return 1
    checkConfig "CONFIG_NETWORK_MACVLAN_RANGE" && return 1
    checkConfig "CONFIG_NETWORK_MACVLAN_GATEWAY" && return 1
    checkConfig "CONFIG_NETWORK_MACVLAN_PARENT" && return 1
    checkConfig "CONFIG_NETWORK_MACVLAN_STATIC_IP" && return 1
    checkConfig "CONFIG_DOCKER_NETWORK_MACVLAN_NAME" && return 1

    if ! checkSU 2>/dev/null && ! isMeInGroup "$docker_group"; then
        echo >&2 -e "\nCurrent user isn't in $docker_group group, cannot proceed"
        echo >&2 -e "\nAdd current user to $docker_group group or run this script as root"
        return 1
    fi

    docker network create -d macvlan \
        --subnet="$CONFIG_NETWORK_MACVLAN_SUBNET" \
        --ip-range="$CONFIG_NETWORK_MACVLAN_RANGE" \
        --gateway="$CONFIG_NETWORK_MACVLAN_GATEWAY" \
        -o parent="$CONFIG_NETWORK_MACVLAN_PARENT" \
        --aux-address="macvlan_bridge=$CONFIG_NETWORK_MACVLAN_STATIC_IP" \
        "$CONFIG_DOCKER_NETWORK_MACVLAN_NAME"

    echo "Docker custom MACVLAN network '$CONFIG_DOCKER_NETWORK_MACVLAN_NAME' created"
    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "$SCRIPT_D/utils.sh"
    . "$SCRIPT_D/init.conf"
    createDockerMacvlanNetwork
    exit $?
fi
