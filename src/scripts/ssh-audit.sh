#!/usr/bin/env bash

###############################################################################
# SSH Security Audit Script
#
# Performs automated security assessment of SSH configurations using ssh-audit
# tool with enhanced error handling and performance optimizations.
#
# Author: LaboDJ
# Version: 1.2
# Last Updated: 2025/01/27
###############################################################################

# Enable strict mode for better error handling and debugging (https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/)
set -Eeuo pipefail

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly SCRIPT_DIR
readonly GIT_URL="https://github.com/jtesta/ssh-audit.git"
readonly TOOL_DIR="$SCRIPT_DIR/ssh-audit"
# Default parameters if none provided
readonly DEFAULT_PARAMS="localhost -4"

trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

# shellcheck disable=SC2317
error_handler() {
    local exit_code=$1
    local line_number=$2
    local last_command=$3

    printf "Error at line %d\nCommand: %s\nExit code: %d\n" \
        "$line_number" "$last_command" "$exit_code" >&2
    exit "$exit_code"
}

# Optimized logging function using printf instead of echo
log() {
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2
}

# Check for root privileges - fail fast principle
[[ "${EUID:-$(id -u)}" -eq 0 ]] && {
    log "ERROR" "Do not run as root"
    exit 1
}

# Check dependencies using parallel processing
check_dependencies() {
    local -a missing_deps=()
    for cmd in git python3; do
        command -v "$cmd" >/dev/null 2>&1 || missing_deps+=("$cmd")
    done

    if ((${#missing_deps[@]} > 0)); then
        log "ERROR" "Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi
}

# Update or clone repository with optimized git commands
update_repository() {
    if [[ -d "$TOOL_DIR" ]]; then
        (cd "$TOOL_DIR" && git pull --depth 1 --no-tags) ||
            {
                log "ERROR" "Failed to update repository"
                exit 1
            }
    else
        git clone --depth 1 --no-tags "$GIT_URL" "$TOOL_DIR" ||
            {
                log "ERROR" "Failed to clone repository"
                exit 1
            }
    fi
}

# Main execution block with proper error handling
main() {
    log "INFO" "Starting SSH security audit"

    check_dependencies

    update_repository

    # Verify ssh-audit.py existence
    [[ -f "${TOOL_DIR}/ssh-audit.py" ]] || {
        log "ERROR" "ssh-audit.py not found"
        exit 1
    }

    # Determine parameters to use
    local audit_params
    if [ $# -eq 0 ]; then
        # Split default parameters into array
        read -r -a audit_params <<<"$DEFAULT_PARAMS"
        log "INFO" "Using default parameters: $DEFAULT_PARAMS"
    else
        # Use all passed parameters as array
        audit_params=("$@")
        log "INFO" "Using custom parameters: ${audit_params[*]}"
    fi

    # Execute ssh-audit with timeout and parameters
    log "INFO" "Running ssh-audit..."
    "${TOOL_DIR}/ssh-audit.py" "${audit_params[@]}" || true

    log "INFO" "Audit completed successfully"
}

# Execute main function with all script parameters
main "$@"

exit 0
