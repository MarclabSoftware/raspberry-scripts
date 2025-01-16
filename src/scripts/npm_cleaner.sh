#!/bin/bash

set -euo pipefail # Modalità strict per maggiore sicurezza

# Configurazione
readonly LE_BASE_PATH="${HOME}/docker/npm/letsencrypt"
readonly KEEP_OLD_VERSIONS=1
readonly KEEP_OLD_CSR_DAYS=180
readonly KEEP_OLD_KEYS_DAYS=180

# Logging function
log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

# Verifica directory base
if [[ ! -d "${LE_BASE_PATH}" ]]; then
    log "ERROR" "Let's Encrypt base path ${LE_BASE_PATH} does not exist"
    exit 1
fi

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

get_file_id() {
    local filename="$1"
    if [[ ${filename} =~ [privkey|cert|chain|fullchain]([0-9]+)\.pem$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "-1"
    fi
}

main() {
    # Cleanup CSR and keys directories
    log "INFO" "Starting cleanup of CSR and keys directories"
    cleanup_directory "${LE_BASE_PATH}/csr" '*_csr-certbot.pem' "${KEEP_OLD_CSR_DAYS}"
    cleanup_directory "${LE_BASE_PATH}/keys" '*_key-certbot.pem' "${KEEP_OLD_KEYS_DAYS}"

    # Cleanup live certificates
    if [[ -d "${LE_BASE_PATH}/live" ]]; then
        log "INFO" "Processing live certificates"
        while IFS= read -r -d '' symlink; do
            target=$(readlink -f "${symlink}")
            file_id=$(get_file_id "${target}")

            if [[ ${file_id} -ge 0 ]]; then
                cmp_id=$((file_id - KEEP_OLD_VERSIONS))
                target_dir=$(dirname "${target}")

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

# Esegui lo script
main

exit 0
