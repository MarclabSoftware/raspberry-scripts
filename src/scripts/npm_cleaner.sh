#!/bin/bash

###############################################################################
# Let's Encrypt Certificate Cleanup Script
#
# This script manages Let's Encrypt certificate files by cleaning up old
# certificates, keys, and CSR files. It maintains a specified number of recent
# versions while removing older files to prevent unnecessary disk usage.
#
# Features:
# - Configurable retention periods for different file types
# - Handles symlinks in Let's Encrypt live directory
# - Maintains specified number of recent certificate versions
# - Comprehensive logging
# - Safe file cleanup with error handling
#
# Requirements:
# - Bash shell
# - Access to Let's Encrypt certificate directory
# - Proper file permissions
#
# Configuration:
# - KEEP_OLD_VERSIONS: Number of recent certificate versions to keep
# - KEEP_OLD_CSR_DAYS: Days to keep CSR files
# - KEEP_OLD_KEYS_DAYS: Days to keep key files
#
# Author: LaboDJ
# Version: 1.0
# Last Updated: 2025/01/16
###############################################################################

set -euo pipefail # Enable strict mode for better error handling

# Configuration constants
readonly LE_BASE_PATH="${HOME}/docker/npm/letsencrypt"
readonly KEEP_OLD_VERSIONS=1
readonly KEEP_OLD_CSR_DAYS=180
readonly KEEP_OLD_KEYS_DAYS=180

# Enhanced logging function with timestamp
log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

# Verify base directory exists
if [[ ! -d "${LE_BASE_PATH}" ]]; then
    log "ERROR" "Let's Encrypt base path ${LE_BASE_PATH} does not exist"
    exit 1
fi

# Function to cleanup files in a directory based on age
cleanup_directory() {
    local directory="$1"
    local pattern="$2"
    local days="$3"

    if [[ ! -d "${directory}" ]]; then
        log "WARNING" "Directory ${directory} does not exist, skipping"
        return 0
    fi

    find "${directory}" -name "${pattern}" -type f -mtime "+${days}" -print0 |
        while IFS= read -r -d '' file; do
            log "INFO" "Deleting old file: ${file}"
            rm -f "${file}"
        done
}

# Extract numeric ID from certificate filename
get_file_id() {
    local filename="$1"
    if [[ ${filename} =~ [privkey|cert|chain|fullchain]([0-9]+)\.pem$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "-1"
    fi
}

main() {
    # Cleanup old CSR and keys files
    log "INFO" "Starting cleanup of CSR and keys directories"
    cleanup_directory "${LE_BASE_PATH}/csr" '*_csr-certbot.pem' "${KEEP_OLD_CSR_DAYS}"
    cleanup_directory "${LE_BASE_PATH}/keys" '*_key-certbot.pem' "${KEEP_OLD_KEYS_DAYS}"

    # Process live certificates directory
    if [[ -d "${LE_BASE_PATH}/live" ]]; then
        log "INFO" "Processing live certificates"
        while IFS= read -r -d '' symlink; do
            target=$(readlink -f "${symlink}")
            file_id=$(get_file_id "${target}")

            if [[ ${file_id} -ge 0 ]]; then
                cmp_id=$((file_id - KEEP_OLD_VERSIONS))
                target_dir=$(dirname "${target}")

                # Find and remove old certificate versions
                find "${target_dir}" -name "*.pem" -type f -print0 |
                    while IFS= read -r -d '' archive_file; do
                        current_id=$(get_file_id "${archive_file}")
                        if [[ ${current_id} -lt ${cmp_id} ]]; then
                            log "INFO" "Deleting old certificate: ${archive_file}"
                            rm -f "${archive_file}"
                        fi
                    done
            fi
        done < <(find "${LE_BASE_PATH}/live" -name "privkey.pem" -type l -print0)
    fi

    log "INFO" "Cleanup completed successfully"
}

# Execute the script
main

exit 0
