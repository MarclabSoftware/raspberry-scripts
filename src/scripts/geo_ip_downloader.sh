#!/usr/bin/env bash

###############################################################################
# Universal Geo-IP List Downloader
#
# Author: LaboDJ
# Version: 6.2
# Last Updated: 2025/11/15
#
# This script downloads, parses, and validates Geo-IP lists from various
# providers (ipdeny, ripe, nirsoft) for specified countries. It is designed
# to be called by the main 'ip-blocker.sh' script and generates normalized
# .list.v4 and .list.v6 files.
#
###############################################################################

# Enable strict mode
# -E: Inherit traps (ERR, DEBUG, RETURN) in functions.
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error.
# -o pipefail: The return value of a pipeline is the status of the last
#              command to exit with a non-zero status, or zero if all exit ok.
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
# Required commands for dependency checks
readonly REQUIRED_COMMANDS=(curl grep sed tr awk md5sum cut)
# Max concurrent download jobs for parallel processing
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

# Generic error handler, triggered by 'trap ... ERR'
# @param $1 The line number where the error occurred
handle_error() {
    local exit_code=$?
    local line_number=$1
    log "ERROR" "Script failed at line $line_number with exit code $exit_code"
    exit "$exit_code"
}

# Standardized logging function.
# @param $1 Log level (e.g., INFO, WARN, ERROR)
# @param $2 Log message
log() {
    # Prints timestamp, log level, PID, and message to stderr
    printf '[%s] [%s] [PID:%d] %s\n' "$(date '+%Y-%m-%d %H:%M:%S.%N')" "$1" "$$" "$2" >&2
}
export -f log

# Log an error message and exit with a non-zero status.
# @param $* The error message to log
die() {
    log "ERROR" "$*"
    exit 1
}
export -f die

# Configures signal traps for robust cleanup and interrupt handling.
setup_signal_handlers() {
    # Handle ERR (any command failure)
    trap 'handle_error $LINENO' ERR
    # Handle SIGINT (Ctrl+C)
    trap 'log "INFO" "Received SIGINT"; exit 130' INT
    # Handle SIGTERM (kill)
    trap 'log "INFO" "Received SIGTERM"; exit 143' TERM
    # Handle EXIT (any script exit)
    trap 'cleanup' EXIT
}

# Cleans up temporary resources, primarily the temp directory.
# This function is called automatically on script EXIT.
cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        log "INFO" "Removed temporary directory: $TEMP_DIR"
    fi
}

###################
# Argument Parsing
###################

# Displays the help message and exits.
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

# Parses command-line options using getopts.
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
    
    # The -c (countries) option is non-negotiable.
    if [[ -z "$ALLOWED_COUNTRIES" ]]; then
        log "ERROR" "Country list (-c) is mandatory."
        print_usage
    fi
}

###################
# Utility Functions
###################

# Verifies that all required external commands are installed.
check_dependencies() {
    local missing_commands=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd")
    done
    
    # Specifically check if awk has the log() function, which is
    # required for the RIPE provider's CIDR calculation.
    if ! awk 'BEGIN { exit !(log(8)/log(2) == 3) }' 2>/dev/null; then
         missing_commands+=("awk (with 'log' function support)")
    fi
    
    [[ ${#missing_commands[@]} -eq 0 ]] || die "Missing commands/features: ${missing_commands[*]}"
}

# Centralized, robust function for downloading a file using curl.
# @param $1 The URL to download
# @param $2 The temporary output file path
# @return 0 on success, 1 on failure
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

# Validates a generated IP list before moving it to the final destination.
# This prevents empty or dangerous (e.g., 0.0.0.0/0) lists from being used.
# @param $1 The path to the temporary, processed file
# @param $2 The final destination file path
# @param $3 A human-readable name for logging (e.g., "IPv4 (IT)")
validate_and_move_generated_file() {
    local temp_file="$1"
    local final_file="$2"
    local list_name="$3"

    # Check 1: Ensure the file is not empty.
    if [[ ! -s "$temp_file" ]]; then
        log "WARN" "Generated $list_name list is empty. Ignoring."
        rm -f "$temp_file"
        return
    fi

    # Check 2: Critical safety check.
    # Prevent "allow all" rules from being propagated.
    # Anchored regex prevents false positives (e.g. 90.0.0.0).
    if grep -Eq '^0\.0\.0\.0(/.*)?$|^::/0$' "$temp_file"; then
        log "ERROR" "DANGEROUS entry (e.g., 0.0.0.0/0 or ::/0) found in generated $list_name list. DISCARDING."
        rm -f "$temp_file"
        return
    fi

    mv "$temp_file" "$final_file"
    log "INFO" "Successfully processed generated $list_name list."
}
export -f validate_and_move_generated_file


# A wrapper function that downloads, cleans, and validates a simple list.
# Used by providers like ipdeny.
# @param $1 The URL to download
# @param $2 The final output file path
# @param $3 A human-readable name for logging
download_and_validate_simple() {
    local url="$1"
    local outfile="$2"
    local proto_name="$3" # e.g., "IPv4 (IT)"
    local temp_outfile="$outfile.tmp"

    log "INFO" "Downloading $proto_name list from $url"

    if ! download_file "$url" "$temp_outfile"; then
        log "WARN" "Failed to download $proto_name list. Skipping."
        # We no longer 'touch' an empty file. Failure means no file.
        return
    fi

    # Clean the file: remove comments, blank lines, and DOS carriage returns.
    sed -i -e '/^#/d' -e '/^$/d' "$temp_outfile"
    tr -d '\r' < "$temp_outfile" > "$outfile.clean" && mv "$outfile.clean" "$temp_outfile"

    validate_and_move_generated_file "$temp_outfile" "$outfile" "$proto_name"
}
export -f download_and_validate_simple

# Helper function for parallel processing.
# Blocks execution until a free job slot (from 'jobs -p') is available.
wait_for_job_slot() {
    # '|| true' prevents 'set -e' from exiting if 'wait -n'
    # returns a non-zero status (e.g., if a job failed), allowing
    # the script to continue processing other jobs.
    while (($(jobs -p | wc -l) >= MAX_DOWNLOAD_JOBS)); do
        wait -n || true
    done
}
export -f wait_for_job_slot

###################
# Provider: ipdeny
###################

# Downloads IPv4 and IPv6 lists for a single country from ipdeny.com.
# @param $1 The 2-letter uppercase country code (e.g., IT)
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

# Main function for the 'ipdeny' provider.
# Downloads all specified countries in parallel.
download_provider_ipdeny() {
    log "INFO" "Using provider: ipdeny (Parallel Mode)"
    for code in "${COUNTRY_ARRAY[@]}"; do
        wait_for_job_slot
        # Launch the download in the background
        _download_country_ipdeny "$code" &
    done
    # Wait for all background jobs to complete
    wait
    log "INFO" "ipdeny parallel download complete."
}

###################
# Provider: ripe
###################

# Main function for the 'RIPE' provider.
# This function is monolithic because it downloads one giant database
# file and then parses it locally for all specified countries.
download_provider_ripe() {
    local -r RIPE_URL="https://ftp.ripe.net/pub/stats/ripencc"
    local -r RIPE_FILE="delegated-ripencc-latest"
    TEMP_DIR=$(mktemp -d) || die "Failed to create temp dir for RIPE"
    local ripe_data_file="$TEMP_DIR/$RIPE_FILE"
    local ripe_md5_file="$TEMP_DIR/$RIPE_FILE.md5"
    
    log "INFO" "Using provider: RIPE (Supports IPv4 and IPv6)"
    
    # 1. Download the database and its checksum
    log "INFO" "Downloading RIPE data file..."
    if ! download_file "$RIPE_URL/$RIPE_FILE" "$ripe_data_file"; then
        die "Failed to download RIPE data file"
    fi
    log "INFO" "Downloading RIPE MD5 file..."
    if ! download_file "$RIPE_URL/$RIPE_FILE.md5" "$ripe_md5_file"; then
        die "Failed to download RIPE MD5 file"
    fi

    # 2. Verify checksum
    log "INFO" "Verifying RIPE file checksum..."
    local expected_md5
    expected_md5=$(awk '/MD5/ {print $NF}' "$ripe_md5_file") || die "Failed to read MD5"
    local computed_md5
    computed_md5=$(md5sum "$ripe_data_file" | cut -d' ' -f1)
    if [[ "$expected_md5" != "$computed_md5" ]]; then
        die "RIPE MD5 checksum mismatch! File is corrupt or tampered with."
    fi
    log "INFO" "Checksum OK."

    # 3. Parse the database for each country
    log "INFO" "Parsing RIPE data for all countries (this may take a moment)..."
    for code in "${COUNTRY_ARRAY[@]}"; do
        local code_lower
        code_lower=$(echo "$code" | tr '[:upper:]' '[:lower:]')
        local V4_OUT_FILE="$ALLOW_DIR/$code_lower.list.v4"
        local V6_OUT_FILE="$ALLOW_DIR/$code_lower.list.v6"
        local TEMP_V4_OUT_FILE="$V4_OUT_FILE.tmp"
        local TEMP_V6_OUT_FILE="$V6_OUT_FILE.tmp"
        
        log "INFO" "Processing RIPE data for $code..."
        # Ensure temp files are empty
        true > "$TEMP_V4_OUT_FILE"
        true > "$TEMP_V6_OUT_FILE"
        
        # Pass file paths and country code to awk via environment variables
        export AWK_V4_FILE="$TEMP_V4_OUT_FILE"
        export AWK_V6_FILE="$TEMP_V6_OUT_FILE"
        export AWK_COUNTRY="$code" 
        
        # This awk script filters the RIPE db for the target country
        # and calculates CIDR notation for IPv4 ranges.
        awk '
            BEGIN {
                V4_FILE = ENVIRON["AWK_V4_FILE"]
                V6_FILE = ENVIRON["AWK_V6_FILE"]
                TARGET_COUNTRY = ENVIRON["AWK_COUNTRY"]
                FS = "|"
            }
            
            # Calculates CIDR mask from a host count
            function calculate_v4_cidr(hosts) {
                if (hosts == 0) return 32
                return 32 - (log(hosts)/log(2))
            }
            
            # File format: ...|COUNTRY_CODE|TYPE|START_IP|HOST_COUNT|...|STATUS
            ($2 == TARGET_COUNTRY && $7 == "allocated") {
                if ($3 == "ipv4") {
                    printf "%s/%d\n", $4, calculate_v4_cidr($5) >> V4_FILE
                }
                if ($3 == "ipv6") {
                    # IPv6 format is simpler: START_IP/PREFIX_LENGTH
                    printf "%s/%s\n", $4, $5 >> V6_FILE
                }
            }
        ' "$ripe_data_file"
        
        unset AWK_V4_FILE AWK_V6_FILE AWK_COUNTRY
        
        # 4. Validate the resulting files
        validate_and_move_generated_file "$TEMP_V4_OUT_FILE" "$V4_OUT_FILE" "IPv4 ($code, RIPE)"
        validate_and_move_generated_file "$TEMP_V6_OUT_FILE" "$V6_OUT_FILE" "IPv6 ($code, RIPE)"
    done
}
###################
# Provider: nirsoft
###################

# Downloads and parses an IPv4 list for a single country from nirsoft.net.
# Nirsoft provides CSV data that must be converted. It does not provide IPv6 data.
# @param $1 The 2-letter uppercase country code (e.g., IT)
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
    
    # We need a temp dir to store the downloaded CSV
    temp_csv_file=$(mktemp --tmpdir="$TEMP_DIR") || die "Failed to create temp file"

    log "INFO" "Downloading $list_name CSV from $URL"
    
    if ! download_file "$URL" "$temp_csv_file"; then
        log "WARN" "Failed to download Nirsoft CSV for $code. Skipping."
        rm -f "$temp_csv_file"
        return # Exit this sub-function
    fi

    # Parse the CSV. Format: Start IP, End IP, ..., ...
    # We convert "Start IP, End IP" to "StartIP - EndIP" for iprange
    awk -F',' 'NF>4 {printf "%s - %s\n", $1, $2}' "$temp_csv_file" > "$TEMP_V4_OUT_FILE"
    rm -f "$temp_csv_file" # Clean up downloaded CSV

    validate_and_move_generated_file "$TEMP_V4_OUT_FILE" "$V4_OUT_FILE" "$list_name"
    
    # Nirsoft provides no IPv6 data.
    # We create an empty v6 file so 'ip-blocker.sh' can find it.
    touch "$V6_OUT_FILE" 
}
export -f _download_country_nirsoft

# Main function for the 'nirsoft' provider.
# Downloads all specified countries in parallel.
download_provider_nirsoft() {
    TEMP_DIR=$(mktemp -d) || die "Failed to create temp dir for Nirsoft"
    log "INFO" "Using provider: Nirsoft (Parallel Mode, IPv4 only)"
    for code in "${COUNTRY_ARRAY[@]}"; do
        wait_for_job_slot
        _download_country_nirsoft "$code" &
    done
    wait
    log "INFO" "Nirsoft parallel download complete."
}

###################
# Main Logic
###################

# Main execution body of the script.
main() {
    # 1. Setup traps and parse arguments
    setup_signal_handlers
    parse_arguments "$@"
    
    # 2. Check for all required tools
    check_dependencies

    # 3. Create the output directory
    mkdir -p "$ALLOW_DIR" || die "Failed to create directory: $ALLOW_DIR"

    # 4. Clean up any lists from a previous run
    log "INFO" "Cleaning old downloaded lists from $ALLOW_DIR"
    rm -f "$ALLOW_DIR"/*.list.v4
    rm -f "$ALLOW_DIR"/*.list.v6

    # 5. Sanitize the user-provided country list
    log "INFO" "Sanitizing country list: $ALLOWED_COUNTRIES"
    
    # Sanitize the input:
    # 1. Convert to uppercase
    # 2. Remove all whitespace (handles "IT, FR")
    # 3. Convert commas to newlines for safe looping
    local sanitized_list
    sanitized_list=$(echo "$ALLOWED_COUNTRIES" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]' | tr ',' '\n')

    COUNTRY_ARRAY=()
    # Read the sanitized list line by line
    while IFS= read -r code; do
        # Only add non-empty lines (handles "IT,,FR")
        if [[ -n "$code" ]]; then
            COUNTRY_ARRAY+=("$code")
        fi
    done <<< "$sanitized_list" # Feed the sanitized list into the loop

    log "INFO" "Processing countries: ${COUNTRY_ARRAY[*]}"
    [[ ${#COUNTRY_ARRAY[@]} -gt 0 ]] || die "No valid country codes provided after sanitization."

    # 6. Dispatch to the correct provider function
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

    # 7. Final Validation
    # This is a critical safety net. If *all* downloads failed
    # (e.g., provider is down, no internet), we must abort.
    log "INFO" "Final check for generated lists..."
    
    # 'find' is safer than 'ls' for this.
    # We just need to know if *at least one* file was created.
    local file_count
    file_count=$(find "$ALLOW_DIR" -maxdepth 1 \( -name "*.list.v4" -o -name "*.list.v6" \) -print 2>/dev/null | wc -l)
    
    if [[ $file_count -eq 0 ]]; then
        die "DOWNLOAD FAILED. No Geo-IP lists were generated (provider unreachable?). Aborting to preserve existing firewall rules."
    fi

    log "INFO" "All country lists processed successfully."
}

# Pass all command-line arguments to the main function
main "$@"