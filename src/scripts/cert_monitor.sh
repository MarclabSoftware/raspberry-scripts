#!/usr/bin/env bash

# =============================================================================
# Certificate Monitor and Converter Script
# =============================================================================
#
# Monitors certificate changes from either Nginx Proxy Manager (PEM files)
# or Traefik (acme.json) and automatically converts the specified
# certificate to PFX format for Technitium DNS Server.
#
# Features:
# - Dual-mode operation (NPM or TRAEFIK) via a single setting.
# - Directory/file monitoring with inotify.
# - PEM-to-PFX conversion (for NPM).
# - acme.json (Base64)-to-PFX conversion (for Traefik).
# - Systemd service support.
# - Robust error handling and logging.
# - Process substitution for Traefik mode (avoids temp files).
# - Atomic file writes to prevent data corruption.
# - Automatic retry logic for Traefik extraction.
#
# Requirements:
# - Common: openssl, inotifywait, flock
# - Traefik Mode: jq, base64, sudo (NOPASSWD for jq, test, inotifywait)
# - Non-root user
#
# Author: LaboDJ
# Version: 2.1
# Last Updated: 2025/11/20
# =============================================================================

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# --- Configuration ---
#
# Select the mode this script should run in.
# Valid options: "NPM" or "TRAEFIK"
#
declare -r MONITOR_MODE="TRAEFIK"

# --- General Settings ---
declare -r DOCKER_DIR="${HOME}/docker"
declare -r TECHNITIUM_DNS_DIR="${DOCKER_DIR}/technitium-dns/mnt/data"
declare -r NEW_CERT_NAME="certificate"
declare -r TARGET_PFX="${TECHNITIUM_DNS_DIR}/${NEW_CERT_NAME}.pfx"

# --- NPM Mode Settings ---
# (Only used if MONITOR_MODE="NPM")
declare -r NPM_CERT_NAME="npm-1"
declare -r NPM_LETSENCRYPT_DIR="${DOCKER_DIR}/nginx_proxy_manager/mnt/letsencrypt"
declare -r NPM_CERT_PATH="${NPM_LETSENCRYPT_DIR}/live/${NPM_CERT_NAME}"

# --- Traefik Mode Settings ---
# (Only used if MONITOR_MODE="TRAEFIK")
declare -r TRAEFIK_ACME_JSON_PATH="/home/labo/docker/pangolin/config/letsencrypt/acme.json"
declare -r TRAEFIK_DOMAIN_TO_EXTRACT="djlabo.com"
declare -r TRAEFIK_RESOLVER_NAME="letsencrypt"

# --- Lock Mechanism ---
declare -r LOCK_FILE="/tmp/cert_monitor.lock"

# --- Logging & Utility Functions ---

# Check if running under systemd
is_systemd() {
    [[ -n "${NOTIFY_SOCKET-}" ]]
}

# Log function with levels
log() {
    local level="INFO"
    if [[ "$1" == "ERROR" || "$1" == "WARN" || "$1" == "INFO" ]]; then
        level="$1"
        shift
    fi
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] $*"
}

# Cleanup function to be called on exit
cleanup() {
    log "INFO" "Releasing lock and cleaning up..."
    # The 'flock' utility releases the lock when the file descriptor is closed.
    rm -f "$LOCK_FILE"
}

# Error handling function
error_exit() {
    log "ERROR" "$*" >&2
    exit 1
}

# Atomic write function for PFX
# Arguments: $1 = Source PFX (temp), $2 = Destination PFX
atomic_move() {
    local src="$1"
    local dest="$2"
    
    if mv -f "$src" "$dest"; then
        chmod 644 "$dest"
        log "INFO" "Certificate successfully updated: $dest"
        return 0
    else
        log "ERROR" "Failed to move temporary file to $dest"
        rm -f "$src"
        return 1
    fi
}

# ----------------------------------------
# Certificate Conversion Functions
# ----------------------------------------

# Converts certificate from NPM (PEM files)
convert_certificate_npm() {
    local fullchain="${NPM_CERT_PATH}/fullchain.pem"
    local privkey="${NPM_CERT_PATH}/privkey.pem"
    local temp_pfx="${TARGET_PFX}.tmp"

    # Wait for file stabilization
    log "INFO" "Waiting for 10 seconds for files to stabilize..."
    sleep 10

    # Check if source files exist and are readable
    [[ ! -r "$fullchain" ]] && { log "ERROR" "Cannot read $fullchain"; return 1; }
    [[ ! -r "$privkey" ]] && { log "ERROR" "Cannot read $privkey"; return 1; }

    log "INFO" "Starting certificate conversion (NPM Mode)"

    if openssl pkcs12 -export \
        -in "$fullchain" \
        -inkey "$privkey" \
        -out "$temp_pfx" \
        -passout pass:"" \
        -passin pass:""; then
        
        atomic_move "$temp_pfx" "$TARGET_PFX"
    else
        log "ERROR" "Certificate conversion failed (NPM Mode)"
        rm -f "$temp_pfx"
        return 1
    fi
}

# Converts certificate from Traefik (acme.json)
convert_certificate_traefik() {
    log "INFO" "Attempting to extract certificate for $TRAEFIK_DOMAIN_TO_EXTRACT (Traefik Mode)"

    # Verify access to acme.json
    if ! sudo test -s "$TRAEFIK_ACME_JSON_PATH"; then
        log "ERROR" "$TRAEFIK_ACME_JSON_PATH not found, is empty, or not accessible via sudo."
        return 1
    fi

    local key_b64
    local cert_b64
    local temp_pfx="${TARGET_PFX}.tmp"

    # Extract Key
    key_b64=$(sudo jq -r --arg r "$TRAEFIK_RESOLVER_NAME" --arg d "$TRAEFIK_DOMAIN_TO_EXTRACT" \
        '.[$r].Certificates | .[]? | select(.domain.main == $d) | .key' "$TRAEFIK_ACME_JSON_PATH")

    # Extract Certificate
    cert_b64=$(sudo jq -r --arg r "$TRAEFIK_RESOLVER_NAME" --arg d "$TRAEFIK_DOMAIN_TO_EXTRACT" \
        '.[$r].Certificates | .[]? | select(.domain.main == $d) | .certificate' "$TRAEFIK_ACME_JSON_PATH")

    # Validate extraction
    if [[ -z "$key_b64" || "$key_b64" == "null" ]]; then
        log "WARN" "Private key not found for $TRAEFIK_DOMAIN_TO_EXTRACT (Resolver: $TRAEFIK_RESOLVER_NAME)."
        return 1
    fi
    if [[ -z "$cert_b64" || "$cert_b64" == "null" ]]; then
        log "WARN" "Certificate not found for $TRAEFIK_DOMAIN_TO_EXTRACT (Resolver: $TRAEFIK_RESOLVER_NAME)."
        return 1
    fi

    log "INFO" "Certificate and key extracted. Starting PFX conversion..."

    if openssl pkcs12 -export \
        -in <(echo "$cert_b64" | base64 -d) \
        -inkey <(echo "$key_b64" | base64 -d) \
        -out "$temp_pfx" \
        -name "$TRAEFIK_DOMAIN_TO_EXTRACT" \
        -passout pass:"" \
        -passin pass:""; then

        atomic_move "$temp_pfx" "$TARGET_PFX"
        return 0
    else
        log "ERROR" "OpenSSL conversion failed (Traefik Mode)."
        rm -f "$temp_pfx"
        return 1
    fi
}

# Retry wrapper for Traefik conversion
convert_with_retry() {
    local max_retries=6
    local retry_delay=10
    local attempt=1
    local success=false

    log "INFO" "Starting conversion sequence... (Max $max_retries attempts)"
    
    # Initial stabilization wait
    sleep 5

    while [[ $attempt -le $max_retries ]]; do
        log "INFO" "Conversion attempt $attempt/$max_retries..."
        
        if convert_certificate_traefik; then
            log "INFO" "Conversion successful on attempt $attempt."
            return 0
        else
            log "WARN" "Conversion failed (file likely incomplete or locked)."
            if [[ $attempt -lt $max_retries ]]; then
                log "INFO" "Waiting ${retry_delay}s before next attempt..."
                sleep $retry_delay
            fi
        fi
        ((attempt++))
    done

    log "ERROR" "All $max_retries conversion attempts failed."
    return 1
}

# ----------------------------------------
# Monitoring Functions
# ----------------------------------------

monitor_npm() {
    log "INFO" "Watching directory: $NPM_CERT_PATH"
    inotifywait -m -e create,modify,moved_to --format '%e %f' "$NPM_CERT_PATH" |
        while read -r event filename; do
            if [[ "$filename" == "fullchain.pem" ]]; then
                log "INFO" "Detected ${event} event on fullchain.pem"
                convert_certificate_npm || log "ERROR" "NPM conversion failed, waiting for next event."
            fi
        done
}

monitor_traefik() {
    local watch_dir
    local watch_file
    
    watch_dir=$(dirname "$TRAEFIK_ACME_JSON_PATH")
    watch_file=$(basename "$TRAEFIK_ACME_JSON_PATH")

    log "INFO" "Watching for changes to '$watch_file' in directory: $watch_dir"
    
    # SUDO: monitor *directory* for events
    sudo inotifywait -m -e modify,create,moved_to "$watch_dir" --format '%e %f' |
        while read -r event filename; do
            if [[ "$filename" == "$watch_file" ]]; then
                log "INFO" "Detected ${event} event on ${watch_file}"
                convert_with_retry
            fi
        done
}

# --- Pre-run Checks ---

log "INFO" "Starting pre-run checks..."

# Check for non-root user
[[ "$(id -u)" -eq 0 ]] && error_exit "Please run as a normal user"

# Check for common required commands
for cmd in openssl inotifywait flock; do
    command -v "$cmd" >/dev/null 2>&1 || error_exit "$cmd not installed"
done

# Check for common directory
[[ ! -d "$TECHNITIUM_DNS_DIR" ]] && error_exit "Target Directory $TECHNITIUM_DNS_DIR does not exist"

# Check write permission to target directory
if [[ ! -w "$TECHNITIUM_DNS_DIR" ]]; then
    error_exit "Target Directory $TECHNITIUM_DNS_DIR is not writable"
fi

# Mode-specific checks
case "$MONITOR_MODE" in
    "NPM")
        log "INFO" "Mode: NPM. Checking NPM-specific settings..."
        [[ ! -d "$NPM_CERT_PATH" ]] && error_exit "NPM Certificate Directory $NPM_CERT_PATH does not exist"
        ;;
    "TRAEFIK")
        log "INFO" "Mode: TRAEFIK. Checking Traefik-specific settings..."
        for cmd in jq base64 sudo; do
            command -v "$cmd" >/dev/null 2>&1 || error_exit "$cmd not installed (required for Traefik mode)"
        done
        
        # Check sudo access (non-interactive)
        if ! sudo -n true 2>/dev/null; then
            log "WARN" "Sudo requires a password or is not configured. This script requires passwordless sudo for 'jq', 'test', and 'inotifywait'."
            # We don't exit here, but warn the user.
        fi

        # SUDO: Use 'sudo test' to check for the file
        if ! sudo test -f "$TRAEFIK_ACME_JSON_PATH"; then
             error_exit "Traefik acme.json file $TRAEFIK_ACME_JSON_PATH not found or not accessible via sudo"
        fi
        ;;
    *)
        error_exit "Invalid MONITOR_MODE: '${MONITOR_MODE}'. Must be 'NPM' or 'TRAEFIK'."
        ;;
esac

log "INFO" "Pre-run checks passed."

# --- Main Execution ---

# Open lock file on file descriptor 200. Create it if it doesn't exist.
exec 200>"$LOCK_FILE" || error_exit "Cannot open lock file ${LOCK_FILE}"

# Try to acquire an exclusive, non-blocking lock.
if ! flock -n 200; then
    error_exit "Script is already running."
fi

# Trap signals for clean exit
trap 'cleanup; exit 0' SIGINT SIGTERM

log "INFO" "Starting certificate monitor in ${MONITOR_MODE} mode."

# Notify systemd that the service is initialized
if is_systemd; then
    systemd-notify --ready
    log "INFO" "Systemd service notified: READY"
fi

# --- Initial Conversion ---
# Run conversion once on startup to ensure PFX is up-to-date
log "INFO" "Performing initial conversion on startup..."
case "$MONITOR_MODE" in
    "NPM")
        convert_certificate_npm || log "WARN" "Initial NPM conversion skipped (files might not exist yet)."
        ;;
    "TRAEFIK")
        convert_certificate_traefik || log "WARN" "Initial Traefik conversion skipped (acme.json might be empty or domain not found)."
        ;;
esac

# --- Monitoring Loop ---
log "INFO" "Starting monitoring loop..."
case "$MONITOR_MODE" in
    "NPM")
        monitor_npm
        ;;
    "TRAEFIK")
        monitor_traefik
        ;;
esac