#!/usr/bin/env bash

###############################################################################
# Country IP List Downloader
#
# This helper script is designed to be called by 'ip-blocker-v4.sh'.
# It downloads aggregated Geo-IP zone files from ipdeny.com for
# both IPv4 and IPv6.
#
# Features:
# - Fetches highly optimized "aggregated" lists from ipdeny.com.
# - Downloads both IPv4 and IPv6 lists separately.
# - Cleans downloaded files: removes comments, blank lines, and
#   Windows-style line endings (\r).
# - Creates empty files on download failure to prevent errors
#   in the main script.
# - Saves output to 'lists/allow/' with '.list.v4' and '.list.v6'
#   suffixes, allowing manual files (e.g. 'manual.v4') to co-exist.
#
# Usage:
#   ./country_ips_downloader_ipdeny.sh -c <COUNTRIES>
#
# Example:
#   ./country_ips_downloader_ipdeny.sh -c IT,DE,FR
#
# Requirements:
#   - curl
#   - An active internet connection.
#   - A 'lists/allow' directory (which it will create).
#
# Author: LaboDJ
# Version: 1.0
# Last Updated: 2025/11/10
###############################################################################

# Enable strict mode for better error handling and debugging
set -euo pipefail

# --- Configuration ---
# Get the script's absolute directory
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
readonly SCRIPT_DIR
# Define the output directory for allowed lists
readonly ALLOW_DIR="$SCRIPT_DIR/lists/allow"
# Define base URLs for the aggregated zone files
readonly V4_URL_BASE="http://www.ipdeny.com/ipblocks/data/aggregated"
readonly V6_URL_BASE="http://www.ipdeny.com/ipv6/ipaddresses/aggregated"
# --- End Configuration ---

# Standardized logging function
log() {
    printf '[%s] [%s] [PID:%d] %s\n' "$(date '+%Y-%m-%d %H:%M:%S.%N')" "$1" "$$" "$2" >&2
}

# Log an error and exit
die() {
    log "ERROR" "$*"
    exit 1
}

# --- Argument Parsing ---
# Ensure the script is called with the '-c' flag
if [[ $# -eq 0 || "$1" != "-c" ]]; then
  die "Usage: $0 -c IT,FR,DE"
fi
readonly COUNTRIES="$2"

# --- Main Logic ---
log "INFO" "Starting download for countries: $COUNTRIES"
# Ensure the target directory exists
mkdir -p "$ALLOW_DIR" || die "Failed to create directory: $ALLOW_DIR"

# Clean up only the files this script is responsible for.
# This prevents deleting manual lists like 'manual.v4'.
log "INFO" "Cleaning old lists from $ALLOW_DIR"
rm -f "$ALLOW_DIR"/*.list.v4
rm -f "$ALLOW_DIR"/*.list.v6

# Convert the comma-separated string (e.g., "IT,FR") into a bash array
IFS=',' read -r -a COUNTRY_ARRAY <<< "$COUNTRIES"

# Reusable download function
download_list() {
    local url="$1"
    local outfile="$2"
    local proto="$3"

    # Download the list and clean it in one pipe:
    # 1. curl: Download the file. --fail causes it to exit > 0 on HTTP errors.
    # 2. grep: Filter out comment lines (starting with #).
    # 3. sed: Remove any blank lines.
    # 4. tr: Remove carriage returns (\r) to fix Windows line endings.
    if ! curl -sSL --fail "$url" | grep -v '^#' | sed '/^$/d' | tr -d '\r' > "$outfile"; then
        # If the download fails, create an empty file.
        # This prevents the main script's 'iprange' or 'cat' commands from failing.
        log "WARN" "Failed to download $proto list from $url. Creating empty file."
        touch "$outfile"
    fi
}

# Loop through each requested country
for code in "${COUNTRY_ARRAY[@]}"; do
    # Convert country code to lowercase for the URL
    code_lower=$(echo "$code" | tr '[:upper:]' '[:lower:]')

    # --- Download IPv4 ---
    V4_URL="$V4_URL_BASE/$code_lower-aggregated.zone"
    V4_OUT_FILE="$ALLOW_DIR/$code_lower.list.v4" # e.g., it.list.v4
    log "INFO" "Downloading IPv4 for $code..."
    download_list "$V4_URL" "$V4_OUT_FILE" "IPv4"

    # --- Download IPv6 ---
    V6_URL="$V6_URL_BASE/$code_lower-aggregated.zone"
    V6_OUT_FILE="$ALLOW_DIR/$code_lower.list.v6" # e.g., it.list.v6
    log "INFO" "Downloading IPv6 for $code..."
    download_list "$V6_URL" "$V6_OUT_FILE" "IPv6"
done

log "INFO" "All country lists downloaded successfully."