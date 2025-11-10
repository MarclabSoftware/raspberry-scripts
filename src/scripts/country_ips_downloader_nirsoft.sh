#!/usr/bin/env bash

###############################################################################
# Script per scaricare ed elaborare liste di IP range da Nirsoft
#
# Questo script scarica i file CSV da Nirsoft per le nazioni specificate,
# li elabora estraendo le prime due colonne e li salva in file .list
# nella directory allowlist.
#
# Usage:
#   ./download_ip_ranges.sh -c it,eg,fr
#
# Requirements:
#   - curl, awk
#
# Author: LaboDJ
# Version: 1.2
# Last Updated: 2025/05/19
###############################################################################

# Enable strict mode
set -Eeuo pipefail

###################
# Global Constants
###################

# URL base per i file CSV di Nirsoft
declare -r NIRSOFT_URL="https://www.nirsoft.net/countryip"

###################
# Global Variables
###################

declare ALLOWED_COUNTRIES=""
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
readonly SCRIPT_DIR
declare TMP_DIR=""

# Directory dove salvare le liste di IP
declare -r ALLOW_LIST_DIR="$SCRIPT_DIR/lists/allow"

###################
# Error Handling
###################

# Enhanced error handling function
handle_error() {
    local exit_code=$?
    local line_number=$1
    log "ERROR" "Script failed at line $line_number with exit code $exit_code"
    exit "$exit_code"
}

# Setup enhanced signal handlers
setup_signal_handlers() {
    # Handle SIGINT (Ctrl+C)
    trap 'log "INFO" "Received SIGINT"; exit 130' INT

    # Handle SIGTERM
    trap 'log "INFO" "Received SIGTERM"; exit 143' TERM

    # Handle ERR
    trap 'handle_error $LINENO' ERR
}

###################
# Logging Functions
###################

# Enhanced logging function with timestamp and PID
log() {
    printf '[%s] [%s] [PID:%d] %s\n' "$(date '+%Y-%m-%d %H:%M:%S.%N')" "$1" "$$" "$2" >&2
}

# Fatal error handler
die() {
    log "ERROR" "$*"
    exit 1
}

###################
# Argument Parsing
###################

# Display usage information
print_usage() {
    cat <<EOF
Usage: $0 -c countries

Options:
    -c countries   Comma-separated list of country codes (e.g., it,eg,fr)
EOF
    exit 1
}

# Parse command line arguments
parse_arguments() {
    [[ $# -eq 0 ]] && print_usage

    while getopts ":c:" opt; do
        case $opt in
        c)
            ALLOWED_COUNTRIES="$OPTARG"
            ;;
        \?)
            log "ERROR" "Invalid option: -$OPTARG"
            print_usage
            ;;
        :)
            log "ERROR" "The option -$OPTARG requires an argument"
            print_usage
            ;;
        esac
    done

    if [[ -z "$ALLOWED_COUNTRIES" ]]; then
        die "No countries specified. Use -c option."
    fi
}

###################
# File Processing Functions
###################

# Download and process IP ranges for a given country
process_country() {
    local country_code="$1"
    local csv_file="$TMP_DIR/${country_code}.csv"
    local list_file="$ALLOW_LIST_DIR/${country_code}.list"
    local url="$NIRSOFT_URL/${country_code}.csv"

    log "INFO" "Downloading IP ranges for $country_code from $url"
    curl -sSL "$url" -o "$csv_file" || die "Failed to download $url"

    # Check if the CSV file is valid (not empty and contains at least 4 columns)
    if [[ ! -s "$csv_file" ]]; then
        log "ERROR" "CSV file for $country_code is empty."
        rm -f "$csv_file"
        return 1
    fi

    # Check if the CSV file has at least 4 columns
    num_commas=$(head -n 2 "$csv_file" | tail -n 1 | tr -cd ',' | wc -c)
    if [[ "$num_commas" -lt 3 ]]; then
        log "ERROR" "CSV file for $country_code is not valid (less than 4 columns)."
        rm -f "$csv_file"
        return 1
    fi

    log "INFO" "Processing $csv_file and saving to $list_file"
    awk -F',' 'NF>4 {printf "%s - %s\n", $1, $2}' "$csv_file" > "$list_file"

    log "INFO" "Processing for $country_code completed."
}


###################
# Main Logic
###################

# Main execution function
main() {
    setup_signal_handlers
    parse_arguments "$@"

    # Convert ALLOWED_COUNTRIES to lowercase
    ALLOWED_COUNTRIES=$(echo "$ALLOWED_COUNTRIES" | tr '[:upper:]' '[:lower:]')

    # Create allowlist directory if it doesn't exist
    mkdir -p "$ALLOW_LIST_DIR" || die "Failed to create directory $ALLOW_LIST_DIR"

    # Create temporary directory
    TMP_DIR=$(mktemp -d) || die "Failed to create temporary directory"
    log "INFO" "Created temporary directory: $TMP_DIR"

    # Trap to remove temporary directory on exit
    trap 'rm -rf "$TMP_DIR"; log "INFO" "Removed temporary directory: $TMP_DIR"' EXIT

    # Process each country
    IFS=',' read -r -a countries <<< "$ALLOWED_COUNTRIES"
    for country in "${countries[@]}"; do
        process_country "$country"
    done

    log "INFO" "All countries processed successfully."
}

main "$@"