#!/usr/bin/env bash

###############################################################################
# Universal Geo-IP List Downloader
#
# Author: LaboDJ
# Version: 6.0 (Fail-Fast & Timeouts)
# Last Updated: 2025/11/14
#
# Changelog v6.0:
# - Added --max-time 30 to curl to prevent hung downloads.
# - Removed "touch" on failure. Failure to download is now silent.
# - Added a final validation block: if NO *.list.v[46] files are
#   produced, the script will exit with an error, preventing the
#   main firewall script from applying empty rules.
###############################################################################

# Enable strict mode
set -Eeuo pipefail

###################
# Global Constants
###################

# Get the script's absolute directory
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
readonly SCRIPT_DIR
# Define the output directory for allowed lists
readonly ALLOW_DIR="$SCRIPT_DIR/lists/allow"
# Default provider if none is specified
readonly DEFAULT_PROVIDER="ipdeny"
# Required commands
readonly REQUIRED_COMMANDS=(curl grep sed tr awk md5sum cut)
# Max concurrent download jobs
readonly MAX_DOWNLOAD_JOBS=4

###################
# Global Variables
###################

declare ALLOWED_COUNTRIES=""
declare PROVIDER="$DEFAULT_PROVIDER"
declare -a COUNTRY_ARRAY=()
declare TEMP_DIR="" # Used for RIPE/Nirsoft downloads

###################
# Error Handling & Logging
###################

# (Funzioni handle_error, cleanup, setup_signal_handlers, log, die... invariate)
# ... (assicurati che -f log e -f die siano esportate) ...
# Standardized logging function
log() {
    printf '[%s] [%s] [PID:%d] %s\n' "$(date '+%Y-%m-%d %H:%M:%S.%N')" "$1" "$$" "$2" >&2
}
export -f log
# Log an error and exit
die() {
    log "ERROR" "$*"
    exit 1
}
export -f die
# (setup_signal_handlers e cleanup invariate)
setup_signal_handlers() {
    trap 'handle_error $LINENO' ERR
    trap 'log "INFO" "Received SIGINT"; exit 130' INT
    trap 'log "INFO" "Received SIGTERM"; exit 143' TERM
    trap 'cleanup' EXIT
}
cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        log "INFO" "Removed temporary directory: $TEMP_DIR"
    fi
}
###################
# Argument Parsing
###################
# (Funzioni print_usage, parse_arguments... invariate)
print_usage() {
    cat <<EOF

Usage: $0 -c COUNTRIES [-p PROVIDER] [-h]

Options:
    -c countries   Comma-separated list of country codes (e.g., IT,DE,FR) [Mandatory]
    -p provider    Data provider: 'ipdeny', 'ripe', 'nirsoft'. (Default: $DEFAULT_PROVIDER)
    -h             Display this help message
EOF
    exit 1
}
parse_arguments() {
    while getopts ":c:p:h" opt; do
        case $opt in
        c) ALLOWED_COUNTRIES="$OPTARG" ;;
        p) PROVIDER="$OPTARG" ;;
        h) print_usage ;;
        \?) log "ERROR" "Invalid option: -$OPTARG"; print_usage ;;
        :) log "ERROR" "The option -$OPTARG requires an argument"; print_usage ;;
        esac
    done
    if [[ -z "$ALLOWED_COUNTRIES" ]]; then
        log "ERROR" "Country list (-c) is mandatory."
        print_usage
    fi
}

###################
# Utility Functions
###################

check_dependencies() {
    local missing_commands=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd")
    done
    if ! awk 'BEGIN { exit !(log(8)/log(2) == 3) }' 2>/dev/null; then
         missing_commands+=("awk (con supporto per la funzione 'log')")
    fi
    [[ ${#missing_commands[@]} -eq 0 ]] || die "Comandi/funzionalità mancanti: ${missing_commands[*]}"
}

# --- MODIFIED: Centralized Robust Download Function ---
download_file() {
    local url="$1"
    local temp_outfile="$2"

    # -sSLf: Silent, follow redirects, fail fast on server errors (4xx, 5xx)
    # --connect-timeout 10: Fail if connection is not made in 10s
    # --max-time 30: Fail if the *entire* download takes longer than 30s
    if ! curl -sSLf --connect-timeout 10 --max-time 30 "$url" -o "$temp_outfile"; then
        log "WARN" "Download failed for $url."
        rm -f "$temp_outfile"
        return 1 # Return failure
    fi
    return 0 # Return success
}
export -f download_file

# --- MODIFIED: Bug fix di validazione ---
validate_and_move_generated_file() {
    local temp_file="$1"
    local final_file="$2"
    local list_name="$3"

    if [[ ! -s "$temp_file" ]]; then
        log "WARN" "Generated $list_name list is empty. Ignoring."
        rm -f "$temp_file"
        return
    fi

    # Regex "ancorata" per evitare falsi positivi (es. 90.0.0.0)
    if grep -Eq '^0\.0\.0\.0(/.*)?$|^::/0$' "$temp_file"; then
        log "ERROR" "DANGEROUS entry (e.g., 0.0.0.0/0 or ::/0) found in generated $list_name list. DISCARDING."
        rm -f "$temp_file"
        return
    fi

    mv "$temp_file" "$final_file"
    log "INFO" "Successfully processed generated $list_name list."
}
export -f validate_and_move_generated_file


# --- MODIFIED: Downloads, cleans, and validates (no 'touch' on fail) ---
download_and_validate_simple() {
    local url="$1"
    local outfile="$2"
    local proto_name="$3" # e.g., "IPv4 (IT)"
    local temp_outfile="$outfile.tmp"

    log "INFO" "Downloading $proto_name list from $url"

    if ! download_file "$url" "$temp_outfile"; then
        log "WARN" "Failed to download $proto_name list. Skipping."
        # RIMOSSO: touch "$outfile"
        return
    fi

    sed -i -e '/^#/d' -e '/^$/d' "$temp_outfile"
    tr -d '\r' < "$temp_outfile" > "$outfile.clean" && mv "$outfile.clean" "$temp_outfile"

    validate_and_move_generated_file "$temp_outfile" "$outfile" "$proto_name"
}
export -f download_and_validate_simple

###################
# Provider: ipdeny
###################

_download_country_ipdeny() {
    local code="$1"
    local code_lower
    code_lower=$(echo "$code" | tr '[:upper:]' '[:lower:]')

    local V4_URL="https://www.ipdeny.com/ipblocks/data/aggregated/$code_lower-aggregated.zone"
    local V4_OUT_FILE="$ALLOW_DIR/$code_lower.list.v4"
    download_and_validate_simple "$V4_URL" "$V4_OUT_FILE" "IPv4 ($code)"

    local V6_URL="https://www.ipdeny.com/ipv6/ipaddresses/aggregated/$code_lower-aggregated.zone"
    local V6_OUT_FILE="$ALLOW_DIR/$code_lower.list.v6"
    download_and_validate_simple "$V6_URL" "$V6_OUT_FILE" "IPv6 ($code)"
}
export -f _download_country_ipdeny

download_provider_ipdeny() {
    log "INFO" "Using provider: ipdeny (Parallel Mode)"
    for code in "${COUNTRY_ARRAY[@]}"; do
        _download_country_ipdeny "$code" &
        while (($(jobs -p | wc -l) >= MAX_DOWNLOAD_JOBS)); do
            wait -n || true
        done
    done
    wait
    log "INFO" "ipdeny parallel download complete."
}

###################
# Provider: ripe
###################
# (Funzione download_provider_ripe... invariata)
download_provider_ripe() {
    local -r RIPE_URL="https://ftp.ripe.net/pub/stats/ripencc"
    local -r RIPE_FILE="delegated-ripencc-latest"
    TEMP_DIR=$(mktemp -d) || die "Failed to create temp dir for RIPE"
    local ripe_data_file="$TEMP_DIR/$RIPE_FILE"
    local ripe_md5_file="$TEMP_DIR/$RIPE_FILE.md5"
    log "INFO" "Using provider: RIPE (Supports IPv4 and IPv6)"
    log "INFO" "Downloading RIPE data file..."
    if ! download_file "$RIPE_URL/$RIPE_FILE" "$ripe_data_file"; then
        die "Failed to download RIPE data file"
    fi
    log "INFO" "Downloading RIPE MD5 file..."
    if ! download_file "$RIPE_URL/$RIPE_FILE.md5" "$ripe_md5_file"; then
        die "Failed to download RIPE MD5 file"
    fi
    log "INFO" "Verifying RIPE file checksum..."
    local expected_md5
    expected_md5=$(awk '/MD5/ {print $NF}' "$ripe_md5_file") || die "Failed to read MD5"
    local computed_md5
    computed_md5=$(md5sum "$ripe_data_file" | cut -d' ' -f1)
    if [[ "$expected_md5" != "$computed_md5" ]]; then
        die "RIPE MD5 checksum mismatch! File is corrupt or tampered with."
    fi
    log "INFO" "Checksum OK."
    log "INFO" "Parsing RIPE data for all countries (this may take a moment)..."
    for code in "${COUNTRY_ARRAY[@]}"; do
        local code_lower
        code_lower=$(echo "$code" | tr '[:upper:]' '[:lower:]')
        local V4_OUT_FILE="$ALLOW_DIR/$code_lower.list.v4"
        local V6_OUT_FILE="$ALLOW_DIR/$code_lower.list.v6"
        local TEMP_V4_OUT_FILE="$V4_OUT_FILE.tmp"
        local TEMP_V6_OUT_FILE="$V6_OUT_FILE.tmp"
        log "INFO" "Processing RIPE data for $code..."
        true > "$TEMP_V4_OUT_FILE"
        true > "$TEMP_V6_OUT_FILE"
        export AWK_V4_FILE="$TEMP_V4_OUT_FILE"
        export AWK_V6_FILE="$TEMP_V6_OUT_FILE"
        export AWK_COUNTRY="$code" 
        awk '
            BEGIN {
                V4_FILE = ENVIRON["AWK_V4_FILE"]
                V6_FILE = ENVIRON["AWK_V6_FILE"]
                TARGET_COUNTRY = ENVIRON["AWK_COUNTRY"]
                FS = "|"
            }
            function calculate_v4_cidr(hosts) {
                if (hosts == 0) return 32
                return 32 - (log(hosts)/log(2))
            }
            ($2 == TARGET_COUNTRY && $7 == "allocated") {
                if ($3 == "ipv4") {
                    printf "%s/%d\n", $4, calculate_v4_cidr($5) >> V4_FILE
                }
                if ($3 == "ipv6") {
                    printf "%s/%s\n", $4, $5 >> V6_FILE
                }
            }
        ' "$ripe_data_file"
        unset AWK_V4_FILE AWK_V6_FILE AWK_COUNTRY
        validate_and_move_generated_file "$TEMP_V4_OUT_FILE" "$V4_OUT_FILE" "IPv4 ($code, RIPE)"
        validate_and_move_generated_file "$TEMP_V6_OUT_FILE" "$V6_OUT_FILE" "IPv6 ($code, RIPE)"
    done
}
###################
# Provider: nirsoft
###################

# --- MODIFIED: _download_country_nirsoft (no 'touch' on fail) ---
_download_country_nirsoft() {
    local code="$1"
    local code_lower
    code_lower=$(echo "$code" | tr '[:upper:]' '[:lower:]')
    local V4_OUT_FILE="$ALLOW_DIR/$code_lower.list.v4"
    local V6_OUT_FILE="$ALLOW_DIR/$code_lower.list.v6"
    local TEMP_V4_OUT_FILE="$V4_OUT_FILE.tmp"
    local list_name="IPv4 ($code, Nirsoft)"
    local URL="https://www.nirsoft.net/countryip/$code_lower.csv"
    local temp_csv_file
    temp_csv_file=$(mktemp --tmpdir="$TEMP_DIR") || die "Failed to create temp file"

    log "INFO" "Downloading $list_name CSV from $URL"
    
    if ! download_file "$URL" "$temp_csv_file"; then
        log "WARN" "Failed to download Nirsoft CSV for $code. Skipping."
        # RIMOSSO: touch "$V4_OUT_FILE"
        # RIMOSSO: touch "$V6_OUT_FILE"
        rm -f "$temp_csv_file"
        return # Exit this sub-function
    fi

    awk -F',' 'NF>4 {printf "%s - %s\n", $1, $2}' "$temp_csv_file" > "$TEMP_V4_OUT_FILE"
    rm -f "$temp_csv_file" # Clean up downloaded CSV

    validate_and_move_generated_file "$TEMP_V4_OUT_FILE" "$V4_OUT_FILE" "$list_name"
    # Create empty v6 file *only on success*
    touch "$V6_OUT_FILE" 
}
export -f _download_country_nirsoft

# (Funzione download_provider_nirsoft... invariata)
download_provider_nirsoft() {
    TEMP_DIR=$(mktemp -d) || die "Failed to create temp dir for Nirsoft"
    log "INFO" "Using provider: Nirsoft (Parallel Mode, IPv4 only)"
    for code in "${COUNTRY_ARRAY[@]}"; do
        _download_country_nirsoft "$code" &
        while (($(jobs -p | wc -l) >= MAX_DOWNLOAD_JOBS)); do
            wait -n || true
        done
    done
    wait
    log "INFO" "Nirsoft parallel download complete."
}

###################
# Main Logic
###################
main() {
    setup_signal_handlers
    parse_arguments "$@"
    check_dependencies

    mkdir -p "$ALLOW_DIR" || die "Failed to create directory: $ALLOW_DIR"

    log "INFO" "Cleaning old downloaded lists from $ALLOW_DIR"
    rm -f "$ALLOW_DIR"/*.list.v4
    rm -f "$ALLOW_DIR"/*.list.v6

    log "INFO" "Sanitizing country list: $ALLOWED_COUNTRIES"
    local upper_countries
    upper_countries=$(echo "$ALLOWED_COUNTRIES" | tr '[:lower:]' '[:upper:]')
    local temp_array
    IFS=',' read -r -a temp_array <<< "$upper_countries"
    COUNTRY_ARRAY=()
    for code in "${temp_array[@]}"; do
        local trimmed_code
        trimmed_code=$(echo "$code" | xargs)
        if [[ -n "$trimmed_code" ]]; then
            COUNTRY_ARRAY+=("$trimmed_code")
        fi
    done
    log "INFO" "Processing countries: ${COUNTRY_ARRAY[*]}"
    [[ ${#COUNTRY_ARRAY[@]} -gt 0 ]] || die "Nessun codice paese valido fornito dopo la sanitizzazione."


    # Dispatch to the correct provider function
    case "$PROVIDER" in
    "ipdeny")
        download_provider_ipdeny
        ;;
    "ripe")
        download_provider_ripe
        ;;
    "nirsoft")
        download_provider_nirsoft
        ;;
    *)
        die "Unknown or unsupported provider: '$PROVIDER'"
        ;;
    esac

    # --- NUOVA VALIDAZIONE FINALE ---
    log "INFO" "Verifica finale delle liste generate..."
    # 'ls' fallirà se non trova file, '2>/dev/null' lo sopprime.
    local file_count
    file_count=$(find "$ALLOW_DIR" -maxdepth 1 \( -name "*.list.v4" -o -name "*.list.v6" \) -print 2>/dev/null | wc -l)
    
    if [[ $file_count -eq 0 ]]; then
        die "DOWNLOAD FALLITO. Nessuna lista Geo-IP è stata generata (provider irraggiungibile?). L'operazione è annullata per preservare le regole firewall esistenti."
    fi
    # --- FINE VALIDAZIONE ---

    log "INFO" "All country lists processed successfully."
}

# Pass all command-line arguments to the main function
main "$@"