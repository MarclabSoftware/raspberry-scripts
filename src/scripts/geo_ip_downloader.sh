#!/usr/bin/env bash

###############################################################################
# Universal Geo-IP List Downloader
#
# Backend utility for 'ip-blocker.sh'. Downloads, parses, and validates
# Geo-IP lists from multiple providers (ipdeny, ripe, nirsoft) using an
# advanced, per-provider country specification syntax.
#
# Core Features:
# - Multi-Provider: Supports 'ipdeny', 'ripe' (DB parsing), & 'nirsoft' (CSV).
# - Advanced Syntax: Accepts provider-specific country lists (e.g., 'ripe:IT;ipdeny:CN').
# - Parallel & Safe: Runs concurrent downloads and validates all lists to
#   remove empty or unsafe entries (e.g., 0.0.0.0/0).
# - Normalized Output: Generates standardized '.list.v4' and '.list.v6' files
#   ready for consumption by 'ip-blocker.sh'.
#
# Usage:
#   ./geo_ip_downloader.sh -c SYNTAX [-h]
#
# Options:
#   -c syntax   Provider/country list [Mandatory].
#               Example: 'ripe:IT,FR;ipdeny:CN,KR;nirsoft:DE'
#   -h          Display this help message.
#
# Environment:
#   DNS_SERVERS    Custom DNS servers for early-boot resolution (e.g. "8.8.8.8 1.1.1.1")
#
# Author: LaboDJ
# Version: 6.7
# Last Updated: 2026/03/25
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
# Required commands for dependency checks (base set; provider-specific added later)
readonly REQUIRED_COMMANDS=(curl grep sed awk cut)
# Max concurrent download jobs for parallel processing
readonly MAX_DOWNLOAD_JOBS=4
# Maximum download retry attempts (exponential backoff: 2s, 4s, 8s...)
readonly MAX_DOWNLOAD_RETRIES=5
# Allowed provider keys
declare -ra ALLOWED_PROVIDERS=(ipdeny ripe nirsoft)

###################
# Global Variables
###################

declare ALLOWED_COUNTRIES_SYNTAX="" # e.g., "ripe:IT,FR;ipdeny:CN"
declare TEMP_DIR="" # Used for RIPE/Nirsoft downloads
# Cache for resolved hostnames to avoid redundant 'dig' calls
declare -A RESOLVED_HOSTS_CACHE

###################
# Error Handling & Logging
###################
#
# NOTE (DRY): handle_error, log, die, and _resolve_hostname are intentionally
# duplicated from ip-blocker.sh. Per the project architecture, scripts are
# fully standalone with no shared library. Any changes here must be mirrored
# in ip-blocker.sh and vice versa.
#

# Generic error handler, triggered by 'trap ... ERR'.
# @param $1 The line number where the error occurred (passed as $LINENO from the trap).
handle_error() {
    local exit_code=$?
    local line_number=$1
    local i stack_trace=""
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
        stack_trace+="${FUNCNAME[$i]}(L${BASH_LINENO[$((i-1))]})"
        ((i < ${#FUNCNAME[@]} - 1)) && stack_trace+=" → "
    done
    log "ERROR" "Script failed at line $line_number with exit code $exit_code | stack: $stack_trace"
    exit "$exit_code"
}

# Standardized logging function.
# @param $1 Log level (e.g., INFO, WARN, ERROR)
# @param $2 Log message
log() {
    # Uses bash builtin printf '%()T' to avoid date subshell overhead
    printf '[%(%Y-%m-%d %H:%M:%S)T] [%s] [PID:%d] %s\n' -1 "$1" "$$" "$2" >&2
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

Usage: $0 -c PROVIDER:COUNTRIES_LIST[;PROVIDER2:LIST2...] [-h]

Description:
    Downloads and parses Geo-IP lists from specified providers.
    Generates standardized .list.v4 and .list.v6 files in the 'lists/allow' directory.

Options:
    -c syntax   Provider and country list specification. [Mandatory]
                Format: 'provider:CC,CC;provider:CC'
                
                Examples:
                  Single provider:   'ipdeny:US,CA'
                  Multiple providers: 'ripe:IT,FR;ipdeny:CN,KR;nirsoft:DE'
                  
    -h          Display this help message.

Providers:
    ipdeny      - Aggregated zones (IPv4 & IPv6). Good general coverage.
    ripe        - RIPE NCC Database (IPv4 & IPv6). High accuracy for Europe/Middle East.
    nirsoft     - CSV format (IPv4 only). Good alternative source.
EOF
    exit 1
}

# Parses command-line options using getopts.
parse_arguments() {
    while getopts ":c:h" opt; do
        case $opt in
        c) ALLOWED_COUNTRIES_SYNTAX="$OPTARG" ;;
        h) print_usage ;;
        \?) log "ERROR" "Invalid option: -$OPTARG"; print_usage ;;
        :) log "ERROR" "The option -$OPTARG requires an argument"; print_usage ;;
        esac
    done

    # The -c (countries) option is non-negotiable.
    if [[ -z "$ALLOWED_COUNTRIES_SYNTAX" ]]; then
        log "ERROR" "Country/Provider syntax (-c) is mandatory."
        print_usage
    fi
}

###################
# Utility Functions
###################

# Verifies that all required external commands are installed.
# @param $1 (optional) Space-separated list of extra commands to check
check_dependencies() {
    local missing_commands=()
    local -a all_commands=("${REQUIRED_COMMANDS[@]}")

    # Append provider-specific commands if requested
    if [[ -n "${1:-}" ]]; then
        read -ra extra <<< "$1"
        all_commands+=("${extra[@]}")
    fi

    for cmd in "${all_commands[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd")
    done

    # Specifically check if awk has the log() function, which is
    # required for the RIPE provider's CIDR calculation.
    if ! awk 'BEGIN { exit !(log(8)/log(2) == 3) }' 2>/dev/null; then
         missing_commands+=("awk (with 'log' function support)")
    fi

    [[ ${#missing_commands[@]} -eq 0 ]] || die "Missing commands/features: ${missing_commands[*]}"
}

# Logs the current DNS configuration for early-boot stability.
log_dns_config() {
    if [[ -n "${DNS_SERVERS:-}" ]]; then
        log "INFO" "Custom DNS resolution active (Servers: $DNS_SERVERS)"
    else
        log "INFO" "Custom DNS resolution disabled (using system resolver)"
    fi
}

# Internal helper to resolve a hostname via specific DNS servers provided in DNS_SERVERS.
# It uses an associative array to cache results for the current execution.
# @param $1 Hostname
# @return Space-separated IPs
_resolve_hostname() {
    local host="$1"
    [[ -z "${DNS_SERVERS:-}" ]] && return 0
    # Return from cache if available
    [[ -n "${RESOLVED_HOSTS_CACHE[$host]:-}" ]] && { echo "${RESOLVED_HOSTS_CACHE[$host]}"; return 0; }

    local -a ips=()
    local -a servers=()
    if [[ -n "${DNS_SERVERS:-}" ]]; then
        read -ra servers <<< "${DNS_SERVERS:-}"
    fi

    # Try each DNS server until one succeeds
    for ns in "${servers[@]}"; do
        # Extract IPv4 (A) as it is the most common fallback needed.
        local res
        res=$(dig +short "@$ns" "$host" A 2>/dev/null | grep -E '^[0-9.]+$' || true)
        if [[ -n "$res" ]]; then
            while read -r ip; do ips+=("$ip"); done <<< "$res"
            break # Stop at first successful resolver
        fi
    done

    if [[ ${#ips[@]} -gt 0 ]]; then
        RESOLVED_HOSTS_CACHE[$host]="${ips[*]}"
        echo "${ips[*]}"
    fi
}

# Centralized, robust function for downloading a file using curl.
# Includes granular retry logic with exponential backoff and custom DNS resolution.
# @param $1 The URL to download
# @param $2 The temporary output file path
# @return 0 on success, 1 on failure
download_file() {
    local url="$1"
    local temp_outfile="$2"
    local retries=0
    local -a resolve_opts=()

    # 1. Handle custom DNS resolution if DNS_SERVERS is set (for early boot stability)
    if [[ -n "${DNS_SERVERS:-}" ]]; then
        local host port
        host=$(echo "$url" | awk -F[/:] '{print $4}')
        [[ "$url" == https://* ]] && port=443 || port=80
        if [[ "$host" == *:* ]]; then
            port="${host##*:}"
            host="${host%:*}"
        fi

        local -a ips=()
        read -ra ips <<< "$(_resolve_hostname "$host")"
        for ip in "${ips[@]}"; do
            resolve_opts+=("--resolve" "$host:$port:$ip")
        done
    fi

    while ((retries < MAX_DOWNLOAD_RETRIES)); do
        # -sSLf: Silent, follow redirects, fail fast on server errors (4xx, 5xx)
        # --connect-timeout 10: Fail if connection is not made in 10s
        # --max-time 30: Fail if the *entire* download takes longer than 30s
        if curl -sSLf "${resolve_opts[@]}" --connect-timeout 10 --max-time 30 "$url" -o "$temp_outfile"; then
            return 0 # Success
        fi

        ((retries++))
        log "WARN" "Download failed for $url. Retry $retries/$MAX_DOWNLOAD_RETRIES..."
        rm -f "$temp_outfile"
        sleep $((2 ** retries)) # Exponential backoff: 2s, 4s, 8s...
    done

    log "ERROR" "Failed to download $url after $MAX_DOWNLOAD_RETRIES attempts."
    return 1 # Final failure
}
export -f _resolve_hostname
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

    # Check 3: Content Validity Check
    # Ensure the file contains at least one valid-looking IP address, CIDR, or range.
    # This prevents files with only garbage/HTML from being accepted.
    # Accepted formats:
    #   - CIDR:       1.2.3.0/24  or  2001:db8::/32
    #   - Plain IP:   1.2.3.4     or  2001:db8::1
    #   - IP Range:   1.2.3.4 - 5.6.7.8  (Nirsoft provider output, consumed by iprange)
    # We use -m 1 to stop at the first match for efficiency.
    if ! grep -Eq -m 1 '^[0-9a-fA-F:.]+(/[0-9]+)?( - [0-9a-fA-F:.]+(/[0-9]+)?)?$' "$temp_file"; then
         log "WARN" "Generated $list_name list does not contain valid IP data. Ignoring."
         rm -f "$temp_file"
         return
    fi

    mv "$temp_file" "$final_file"
    log "INFO" "Successfully processed generated $list_name list."
}
export -f validate_and_move_generated_file


# A wrapper function that downloads, cleans, and validates a simple list.
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
        return
    fi

    # Clean the file: remove comments, blank lines, and DOS carriage returns.
    sed -i -e '/^#/d' -e '/^$/d' -e 's/\r$//' "$temp_outfile"

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
    local code_lower="${code,,}"

    local V4_URL="https://www.ipdeny.com/ipblocks/data/aggregated/$code_lower-aggregated.zone"
    local V4_OUT_FILE="$ALLOW_DIR/$code_lower.ipdeny.list.v4"
    download_and_validate_simple "$V4_URL" "$V4_OUT_FILE" "IPv4 ($code)"

    local V6_URL="https://www.ipdeny.com/ipv6/ipaddresses/aggregated/$code_lower-aggregated.zone"
    local V6_OUT_FILE="$ALLOW_DIR/$code_lower.ipdeny.list.v6"
    download_and_validate_simple "$V6_URL" "$V6_OUT_FILE" "IPv6 ($code)"
}
export -f _download_country_ipdeny

# Main function for the 'ipdeny' provider.
# @param $@ A list of country codes (e.g., "IT" "FR" "DE")
download_provider_ipdeny() {
    local -a countries=("$@")
    log "INFO" "Using provider: ipdeny (Parallel Mode) for ${countries[*]}"
    for code in "${countries[@]}"; do
        wait_for_job_slot
        # Launch the download in the background
        _download_country_ipdeny "$code" &
    done
    # Wait for all background jobs for this provider to complete
    wait
    log "INFO" "ipdeny download complete for ${countries[*]}"
}

###################
# Provider: ripe
###################

# Main function for the 'RIPE' provider.
# @param $@ A list of country codes (e.g., "IT" "FR" "DE")
download_provider_ripe() {
    local -a ripe_countries=("$@")
    if [[ ${#ripe_countries[@]} -eq 0 ]]; then
        log "WARN" "RIPE provider specified but no countries listed. Skipping."
        return
    fi

    local -r RIPE_URL="https://ftp.ripe.net/pub/stats/ripencc"
    local -r RIPE_FILE="delegated-ripencc-latest"
    local ripe_data_file="$TEMP_DIR/$RIPE_FILE"
    local ripe_md5_file="$TEMP_DIR/$RIPE_FILE.md5"

    log "INFO" "Using provider: RIPE (Supports IPv4 and IPv6) for ${ripe_countries[*]}"

    # 1. Download the database and its checksum (only if not already downloaded)
    if [[ ! -f "$ripe_data_file" ]]; then
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
    else
        log "INFO" "Using cached RIPE data file."
    fi

    # 3. Prepare for single-pass parsing
    log "INFO" "Parsing RIPE data for ${ripe_countries[*]} (Single Pass)..."

    # We construct a string mapping "COUNTRY:V4_FILE|V6_FILE" for awk
    # and prepare the temp files.
    local awk_targets=""
    local -A temp_v4_files
    local -A temp_v6_files

    for code in "${ripe_countries[@]}"; do
        local code_lower="${code,,}"

        local v4_out="$ALLOW_DIR/$code_lower.ripe.list.v4"
        local v6_out="$ALLOW_DIR/$code_lower.ripe.list.v6"
        local temp_v4="$v4_out.tmp"
        local temp_v6="$v6_out.tmp"

        # Ensure temp files are empty/exist
        : > "$temp_v4"
        : > "$temp_v6"

        temp_v4_files[$code]="$temp_v4"
        temp_v6_files[$code]="$temp_v6"

        # Append to target string (space separated)
        awk_targets+="$code:$temp_v4|$temp_v6 "
    done

    export AWK_TARGETS="$awk_targets"

    # 4. Run AWK once
    # This AWK script performs a single-pass scan of the massive RIPE database.
    # It filters entries by country and status, calculates CIDR prefixes for IPv4,
    # and writes directly to the appropriate country/protocol files.
    awk '
        BEGIN {
            # Parse the targets map passed via environment variable.
            # Format: "IT:path/to/v4|path/to/v6 FR:..."
            split(ENVIRON["AWK_TARGETS"], targets, " ")
            for (i in targets) {
                split(targets[i], parts, ":")
                country = parts[1]
                split(parts[2], files, "|")
                file_map_v4[country] = files[1]
                file_map_v6[country] = files[2]
                # Store country in a lookup table for O(1) access
                target_countries[country] = 1
            }
            FS = "|"
        }

        # Calculates CIDR mask from a host count (IPv4 only).
        # RIPE DB gives a number of hosts (e.g., 1024), we need the prefix length (e.g., /22).
        # Formula: 32 - log2(hosts)
        function calculate_v4_cidr(hosts) {
            if (hosts == 0) return 32
            return 32 - (log(hosts)/log(2))
        }

        # Main Loop: Process each line of the RIPE DB
        # Format: registry|cc|type|start|value|date|status
        # $2 = Country Code (e.g., IT)
        # $3 = Type (ipv4, ipv6)
        # $4 = Start IP
        # $5 = Value (Host count for IPv4, Prefix length for IPv6)
        # $7 = Status (allocated, assigned)
        
        ($2 in target_countries && ($7 == "allocated" || $7 == "assigned")) {
            if ($3 == "ipv4") {
                # IPv4: Convert host count to CIDR and append to the countrys v4 file
                printf "%s/%d\n", $4, calculate_v4_cidr($5) >> file_map_v4[$2]
            }
            else if ($3 == "ipv6") {
                # IPv6: Already in CIDR format (Start/Prefix), just append
                printf "%s/%s\n", $4, $5 >> file_map_v6[$2]
            }
        }
    ' "$ripe_data_file"

    unset AWK_TARGETS

    # 5. Validate and move all generated files
    for code in "${ripe_countries[@]}"; do
        local code_lower="${code,,}"
        local v4_out="$ALLOW_DIR/$code_lower.ripe.list.v4"
        local v6_out="$ALLOW_DIR/$code_lower.ripe.list.v6"
        
        # Retrieve temp files from our array
        local temp_v4="${temp_v4_files[$code]}"
        local temp_v6="${temp_v6_files[$code]}"

        validate_and_move_generated_file "$temp_v4" "$v4_out" "IPv4 ($code, RIPE)"
        validate_and_move_generated_file "$temp_v6" "$v6_out" "IPv6 ($code, RIPE)"
    done
}
###################
# Provider: nirsoft
###################

# Downloads and parses an IPv4 list for a single country from nirsoft.net.
# @param $1 The 2-letter uppercase country code (e.g., IT)
_download_country_nirsoft() {
    local code="$1"
    local code_lower="${code,,}"
    local V4_OUT_FILE="$ALLOW_DIR/$code_lower.nirsoft.list.v4"
    local V6_OUT_FILE="$ALLOW_DIR/$code_lower.nirsoft.list.v6"
    local TEMP_V4_OUT_FILE="$V4_OUT_FILE.tmp"
    local list_name="IPv4 ($code, Nirsoft)"
    local URL="https://www.nirsoft.net/countryip/$code_lower.csv"
    local temp_csv_file

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
# @param $@ A list of country codes (e.g., "IT" "FR" "DE")
download_provider_nirsoft() {
    local -a countries=("$@")
    log "INFO" "Using provider: Nirsoft (Parallel Mode, IPv4 only) for ${countries[*]}"
    for code in "${countries[@]}"; do
        wait_for_job_slot
        _download_country_nirsoft "$code" &
    done
    wait
    log "INFO" "Nirsoft parallel download complete for ${countries[*]}"
}

###################
# Main Logic
###################

# Main execution body of the script.
main() {
    # 1. Setup traps and parse arguments
    setup_signal_handlers
    parse_arguments "$@"
    log_dns_config

    # 2. Check for all required tools
    check_dependencies

    # dig is required only when DNS_SERVERS is set (early-boot DNS override)
    if [[ -n "${DNS_SERVERS:-}" ]] && ! command -v dig >/dev/null 2>&1; then
        die "DNS_SERVERS is set but 'dig' (bind-tools/dnsutils) is not installed."
    fi

    # 3. Create the output directory
    mkdir -p "$ALLOW_DIR" || die "Failed to create directory: $ALLOW_DIR"

    # 4. Create shared temp directory for providers that need it (RIPE, Nirsoft)
    TEMP_DIR=$(mktemp -d) || die "Failed to create temp directory"

    # 5. Clean up any lists from a previous run
    log "INFO" "Cleaning old downloaded lists from $ALLOW_DIR"
    rm -f "$ALLOW_DIR"/*.list.v4
    rm -f "$ALLOW_DIR"/*.list.v6

    # 6. Parse the new syntax
    log "INFO" "Parsing provider/country syntax: $ALLOWED_COUNTRIES_SYNTAX"

    # Use an associative array to map providers to their country lists
    declare -A provider_country_map

    # Split on semicolons using parameter expansion (no subshell)
    local -a provider_groups
    IFS=';' read -ra provider_groups <<< "$ALLOWED_COUNTRIES_SYNTAX"

    for group in "${provider_groups[@]}"; do
        [[ -n "$group" ]] || continue # Skip empty entries

        # Split "provider:C1,C2" using parameter expansion
        local provider_name="${group%%:*}"
        provider_name="${provider_name,,}"          # lowercase
        provider_name="${provider_name// /}"         # strip spaces
        local country_list_csv="${group#*:}"         # everything after first colon

        # Validate provider against array
        local valid=false
        for p in "${ALLOWED_PROVIDERS[@]}"; do
            [[ "$p" == "$provider_name" ]] && { valid=true; break; }
        done
        if ! "$valid"; then
            die "Invalid provider '$provider_name' in syntax. Allowed: ${ALLOWED_PROVIDERS[*]}"
        fi

        # Sanitize country list: uppercase, remove spaces, convert comma to space
        local sanitized_countries="${country_list_csv^^}" # uppercase
        sanitized_countries="${sanitized_countries// /}"  # strip spaces
        sanitized_countries="${sanitized_countries//,/ }" # comma → space

        # Append to the map (handles a provider being listed multiple times)
        provider_country_map[$provider_name]+="$sanitized_countries "

    done

    # 7. Check for RIPE-specific dependencies if needed
    if [[ -n "${provider_country_map[ripe]:-}" ]]; then
        check_dependencies "md5sum"
    fi

    # 8. Dispatch to the correct provider functions
    for provider in "${!provider_country_map[@]}"; do
        local -a country_array=()
        # Word-split the space-separated codes robustly (no glob expansion),
        # output one per line for sort -u, then build the final array.
        local -a raw_countries=()
        read -ra raw_countries <<< "${provider_country_map[$provider]}"
        mapfile -t country_array < <(printf '%s\n' "${raw_countries[@]}" | sort -u)

        [[ ${#country_array[@]} -gt 0 ]] || continue # Skip if no countries

        log "INFO" "Dispatching download for provider: $provider (Countries: ${country_array[*]})"

        case "$provider" in
        "ipdeny")
            # Pass the country array to the function
            download_provider_ipdeny "${country_array[@]}"
            ;;
        "ripe")
            # RIPE is monolithic; it must run sequentially in the main thread.
            # Pass the country array to the function.
            download_provider_ripe "${country_array[@]}"
            ;;
        "nirsoft")
            # Pass the country array to the function
            download_provider_nirsoft "${country_array[@]}"
            ;;
        *)
            # This should be unreachable due to validation above
            die "Unknown or unsupported provider: '$provider'"
            ;;
        esac
    done

    # 9. Final Validation
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