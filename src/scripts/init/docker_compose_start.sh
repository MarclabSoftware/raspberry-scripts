#!/usr/bin/env bash

startDockerCompose() {

    echo -e "\n\nStarting docker compose"

    if ! checkCommand "docker"; then
        echo >&2 "docker command missing, cannot proceed"
        return 1
    fi

    local docker_group="docker"
    if ! checkSU 2>/dev/null && ! isMeInGroup "$docker_group"; then
        echo >&2 -e "\nCurrent user isn't in $docker_group group, cannot proceed"
        echo >&2 -e "\nAdd current user to $docker_group group or run this script as root"
        return 1
    fi

    checkConfig "CONFIG_DOCKER_COMPOSE_FILE_PATH" || return 1

    if [ ! -f "$CONFIG_DOCKER_COMPOSE_FILE_PATH" ]; then
        echo "Cannot find $CONFIG_DOCKER_COMPOSE_FILE_PATH compose file, please check"
        paktc
        return 1
    fi

    docker compose -f "$CONFIG_DOCKER_COMPOSE_FILE_PATH" up -d
    echo -e "\nServices in $CONFIG_DOCKER_COMPOSE_FILE_PATH compose file should be up and running"

    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "$SCRIPT_D/utils.sh"
    . "$SCRIPT_D/init.conf"
    startDockerCompose
    exit $?
fi
