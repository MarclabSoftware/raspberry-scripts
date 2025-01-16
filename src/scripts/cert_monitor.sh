#!/bin/bash

# =============================================================================
# Certificate Monitor and Converter Script
# =============================================================================
#
# Monitors Let's Encrypt certificate directory and automatically converts 
# certificates from PEM to PFX format for Technitium DNS Server.
#
# Features:
# - Directory monitoring with inotify
# - PEM to PFX conversion
# - Systemd service support
# - Error handling and logging
#
# Requirements:
# - openssl, inotifywait
# - Non-root user
#
# Author: LaboDJ
# Version: 1.0
# Last Updated: 2025/01/16
# =============================================================================

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Constants - Using more efficient variable declarations
declare -r CERT_NAME="npm-1"
declare -r DOCKER_DIR="${HOME}/docker"
declare -r LETSENCRYPT_DIR="${DOCKER_DIR}/npm/letsencrypt"
declare -r TECHNITIUM_DNS_DIR="${DOCKER_DIR}/technitium-dns"
declare -r NEW_CERT_NAME="certificate"
declare -r CERT_PATH="${LETSENCRYPT_DIR}/live/${CERT_NAME}"
declare -r TARGET_PFX="${TECHNITIUM_DNS_DIR}/${NEW_CERT_NAME}.pfx"

# Check if running under systemd
is_systemd() {
    [[ -n "${NOTIFY_SOCKET-}" ]]
}

# Log function for better debugging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Error handling function
error_exit() {
    log "ERROR: $*" >&2
    exit 1
}

# Check for required commands
for cmd in openssl inotifywait; do
    command -v "$cmd" >/dev/null 2>&1 || error_exit "$cmd not installed"
done

# Check for non-root user
[[ "$(id -u)" -eq 0 ]] && error_exit "Please run as a normal user"

# Check for directory existence with more informative messages
for dir in "$CERT_PATH" "$TECHNITIUM_DNS_DIR"; do
    [[ ! -d "$dir" ]] && error_exit "Directory $dir does not exist"
done

# Function to convert certificate with error handling
convertCertificate() {
    local fullchain="${CERT_PATH}/fullchain.pem"
    local privkey="${CERT_PATH}/privkey.pem"

    # Wait for files to be fully written
    sleep 10

    # Check if source files exist and are readable
    [[ ! -r "$fullchain" ]] && error_exit "Cannot read $fullchain"
    [[ ! -r "$privkey" ]] && error_exit "Cannot read $privkey"

    log "Starting certificate conversion"

    if openssl pkcs12 -export \
        -in "$fullchain" \
        -inkey "$privkey" \
        -out "$TARGET_PFX" \
        -passout pass:"" \
        -passin pass:"" 2>/dev/null; then

        log "Certificate successfully converted to: $TARGET_PFX"

        # Set appropriate permissions
        chmod 644 "$TARGET_PFX"

        # Notify systemd only if running as a service
        if is_systemd; then
            systemd-notify --ready
            log "Systemd service notified"
        fi
    else
        error_exit "Certificate conversion failed"
    fi
}

# Trap signals for clean exit
trap 'log "Script terminated"; exit 0' SIGTERM SIGINT

log "Starting certificate monitor for $CERT_PATH"

# Notify systemd that we're ready to start monitoring
if is_systemd; then
    systemd-notify --ready
    log "Initial systemd service notification sent"
fi

# Monitor directory with improved error handling
inotifywait -m -e create,modify,moved_to --format '%e %f' "$CERT_PATH" 2>/dev/null |
    while read -r event filename; do
        if [[ "$filename" == "fullchain.pem" ]]; then
            log "Detected ${event} event on fullchain.pem"
            convertCertificate &
        fi
    done
