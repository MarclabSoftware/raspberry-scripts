#!/usr/bin/env bash

###############################################################################
# IP-Based Firewall Configuration Script
#
# Configures a robust, hybrid-backend firewall (nftables/iptables) with a
# focus on Geo-IP filtering, SSH brute-force mitigation, and Docker protection.
#
# Core Features:
# - Auto-Backend: Prefers 'nftables', falls back to 'iptables'/'ipset'.
# - Geo-IP Filtering: Full IPv4 & optional IPv6. Supports multiple providers
#   (ipdeny, ripe, nirsoft) and manual 'lists/allow/*.v4' files.
# - Flowtable Offload: Hardware/Software offload for established connections
#   (nftables only) to boost throughput and reduce CPU load.
# - Default Deny Policy: Secures the host (INPUT) while safely filtering
#   Docker traffic (FORWARD) before Docker's own rules.
# - Protection: Robust SSH rate-limiting (v4/v6) using meters (nft) or recent
#   module (iptables), plus IPv4 blocklist support.
# - Safe & Atomic: Applies rules in a single transaction to prevent errors.
# - Robust: Includes connectivity checks, download retries, and error trapping.
#
# Usage:
#   sudo ./ip-blocker.sh [-c COUNTRIES] [-p PROVIDER] [-b] [-G] [-s SSH_PORT] [-i INTERFACES] [-h]
#
# Options:
#   -c countries   Specify allowed countries.
#                  Simple: "IT,DE,FR" (uses provider from -p).
#                  Advanced: "ripe:IT,FR;ipdeny:CN;nirsoft:KR,IT" (ignores -p).
#   -p provider    Geo-IP provider: 'ipdeny', 'ripe', 'nirsoft' (default: ipdeny)
#   -b             Enable (IPv4) blocklists.
#   -G             Enable Geo-blocking for IPv6 (default: false, IPv6 is allowed).
#   -s sshPort     Specify the SSH port (default: 22).
#   -i interfaces  List of interfaces for Flowtable offload (e.g. "eth0 wg0").
#                  Supports wildcards (e.g. "br-* wg* eth*").
#   -h             Display this help message.
#
# Author: LaboDJ
# Version: 5.3
# Last Updated: 2025/12/29
###############################################################################

# Enable strict mode:
# -E: Inherit traps (ERR, DEBUG, RETURN) in functions.
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error.
# -o pipefail: The return value of a pipeline is the status of the last
#              command to exit with a non-zero status, or zero if all exit ok.
set -Eeuo pipefail

###################
# Global Constants
###################

# Default country code if none is specified via -c
declare -r DEFAULT_COUNTRIES="IT"
# Get the script's absolute directory
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
readonly SCRIPT_DIR
# Path to the downloader script
declare -r COUNTRY_IPS_DOWNLOADER="$SCRIPT_DIR/geo_ip_downloader.sh"
# Directory structure
declare -r IP_LIST_DIR="$SCRIPT_DIR/lists"
declare -r ALLOW_LIST_DIR="$IP_LIST_DIR/allow"
declare -r BLOCK_LIST_DIR="$IP_LIST_DIR/block"
# URL for the v4 blocklist index
declare -r BLOCK_LIST_URL="https://raw.githubusercontent.com/Adamm00/IPSet_ASUS/master/filter.list"
declare -r BLOCK_LIST_FILE_NAME="$IP_LIST_DIR/blocklists.txt"
declare -r MANUAL_BLOCK_LIST="$IP_LIST_DIR/manual_blocklist.txt"
# Our main table name for nftables
declare -r NFT_TABLE_NAME="labo_firewall"
# Names for our sets/ipsets
declare -r ALLOW_LIST_NAME_V4="allowlist_v4"
declare -r ALLOW_LIST_NAME_V6="allowlist_v6"
declare -r BLOCK_LIST_NAME_V6="blocklist_v6"
# Geo-IP Provider settings
# Default provider if -p is not used
declare -r DEFAULT_PROVIDER="ipdeny"
declare -r ALLOWED_PROVIDERS="ipdeny ripe nirsoft"
# Max retries for downloader
declare -r MAX_RETRIES=10
# Sites to test connectivity
declare -r CONNECTIVITY_CHECK_SITES=(github.com google.com)
# Lock directory for singleton execution
declare -r LOCK_DIR="/var/run/ip-blocker.lock"

###################
# Global Variables
###################

# These variables are set by parse_arguments()
declare ALLOWED_COUNTRIES="$DEFAULT_COUNTRIES"
declare USE_BLOCKLIST=false
declare SSH_PORT=22
declare GEOBLOCK_IPV6=false # Default: IPv6 is NOT geo-blocked
declare GEO_IP_PROVIDER="$DEFAULT_PROVIDER"
declare FLOWTABLE_INTERFACES=""

# Secure temp directory
declare TEMP_DIR=""
# Final optimized IP list files (path is set in setup_temp_dir_and_traps)
declare IP_RANGE_FILE_V4=""
declare IP_RANGE_FILE_V6=""
declare IP_RANGE_FILE_BLOCK_V6=""

declare CLEANUP_REGISTERED=false
declare FIREWALL_BACKEND=""
declare -a REQUIRED_COMMANDS=()

# Paths for clean intermediate lists
declare BLOCK_LIST_CLEAN_V4_DIR=""
declare BLOCK_LIST_CLEAN_V6_DIR=""

###################
# Error Handling & Logging
###################

# Generic error handler, triggered by 'trap ... ERR'
handle_error() {
    local exit_code=$?
    local line_number=$1
    log "ERROR" "Script failed at line $line_number with exit code $exit_code"
    exit "$exit_code"
}

# Setup signal traps for robust execution and cleanup
setup_signal_handlers() {
    # Handle SIGINT (Ctrl+C)
    trap 'log "INFO" "Received SIGINT"; exit 130' INT
    # Handle SIGTERM (kill)
    trap 'log "INFO" "Received SIGTERM"; exit 143' TERM
    # Handle ERR (any command failure)
    trap 'handle_error $LINENO' ERR
    # Handle EXIT (any script exit)
    trap 'cleanup' EXIT
    # Flag to prevent double cleanup
    CLEANUP_REGISTERED=true
}

# Standardized logging function
log() {
    # Prints timestamp, log level, PID, and message to stderr
    printf '[%s] [%s] [PID:%d] %s\n' "$(date '+%Y-%m-%d %H:%M:%S.%N')" "$1" "$$" "$2" >&2
}

# Log an error and exit
die() {
    log "ERROR" "$*"
    exit 1
}

# Cleanup secure temporary directory on script exit
cleanup() {
    if [[ "$CLEANUP_REGISTERED" == true ]]; then
        log "INFO" "Performing cleanup..."
        if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
            rm -rf "$TEMP_DIR"
            log "INFO" "Removed temporary directory: $TEMP_DIR"
        fi
        if [[ -d "$LOCK_DIR" ]]; then
            rm -rf "$LOCK_DIR"
            log "INFO" "Released lock: $LOCK_DIR"
        fi
    fi
}

# Check for root, create secure temp dir, and setup traps
setup_temp_dir_and_traps() {
    # 1. Check root
    [[ "${EUID:-$(id -u)}" -ne 0 ]] && die "Please run as root/sudo"

    # 2. Acquire Lock (Atomic mkdir)
    # This prevents multiple instances from running simultaneously.
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        # Check if the process holding the lock is still alive
        if [[ -f "$LOCK_DIR/pid" ]]; then
            local lock_pid
            lock_pid=$(cat "$LOCK_DIR/pid")
            if kill -0 "$lock_pid" 2>/dev/null; then
                die "Script is already running (PID: $lock_pid). Aborting."
            else
                log "WARN" "Stale lock found (PID: $lock_pid). Removing..."
                rm -rf "$LOCK_DIR"
                # Try to acquire again
                if ! mkdir "$LOCK_DIR" 2>/dev/null; then
                    die "Failed to acquire lock after removing stale lock."
                fi
            fi
        else
             die "Failed to acquire lock directory: $LOCK_DIR"
        fi
    fi
    # Write our PID to the lock
    echo "$$" > "$LOCK_DIR/pid"

    # 3. Create secure temp directory
    # -t: creates in $TMPDIR or /tmp, with a template
    TEMP_DIR=$(mktemp -d -t ipblocker.XXXXXX) || die "Failed to create secure temp directory"

    # 4. Set global paths for our temp files
    IP_RANGE_FILE_V4="$TEMP_DIR/$ALLOW_LIST_NAME_V4.iprange.txt"
    IP_RANGE_FILE_V6="$TEMP_DIR/$ALLOW_LIST_NAME_V6.iprange.txt"
    IP_RANGE_FILE_BLOCK_V6="$TEMP_DIR/$BLOCK_LIST_NAME_V6.iprange.txt"

    # 5. Setup traps (now that TEMP_DIR and Lock are set)
    setup_signal_handlers
}

###################
# Argument Parsing
###################

# Display usage information
print_usage() {
    cat <<EOF

Usage: $0 [-c countries] [-p provider] [-b] [-G] [-s sshPort] [-i interfaces] [-h]

Options:
    -c countries   Specify allowed countries
                   Simple: "IT,DE,FR" (uses provider from -p).
                   Advanced: "ripe:IT,FR;ipdeny:CN;nirsoft:KR,IT" (ignores -p).
    -p provider    Geo-IP provider: 'ipdeny', 'ripe', 'nirsoft' (default: $DEFAULT_PROVIDER)
    -b             Enable block lists (Applies to IPv4 only by default)
    -G             Enable Geo-blocking for IPv6 (default: false)
    -s sshPort     Specify SSH port (default: 22)
    -i interfaces  Interfaces for Flowtable offload (e.g. "eth0 wg0 br-*")
    -h             Display this help message
EOF
    exit 1
}

# Parse command line arguments using getopts
parse_arguments() {
    if [[ $# -eq 0 ]]; then
      log "WARN" "No arguments provided. Using defaults (Countries: $DEFAULT_COUNTRIES)."
    fi
    OPTIND=1
    local OPTERR=1

    # New loop includes '-G' and '-p'
    while getopts ":c:p:bs:i:hG" opt; do
        case $opt in
        c) ALLOWED_COUNTRIES="$OPTARG" ;;
        p) GEO_IP_PROVIDER="$OPTARG" ;;
        b) USE_BLOCKLIST=true ;;
        G) GEOBLOCK_IPV6=true ;; # Set IPv6 blocking to opt-in
        s) SSH_PORT="$OPTARG" ;;
        i) FLOWTABLE_INTERFACES="$OPTARG" ;;
        h) print_usage ;;
        \?) log "ERROR" "Invalid option: -$OPTARG"; print_usage ;;
        :) log "ERROR" "The option -$OPTARG requires an argument"; print_usage ;;
        esac
    done

    # Validate SSH port is a valid number
    if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        die "SSH port must be a number between 1 and 65535"
    fi
    # Validate country codes based on syntax
    if [[ "$ALLOWED_COUNTRIES" == *":"* ]]; then
        # Advanced syntax (e.g., "ripe:IT,FR;ipdeny:CN")
        # Allows letters, commas, colons, and semicolons
        local adv_regex='^[A-Za-z,;:]+$'
        if [[ ! "$ALLOWED_COUNTRIES" =~ $adv_regex ]]; then
            die "Invalid advanced country syntax. Use format like 'provider:C1,C2;provider2:C3'"
        fi
    else
        # Simple syntax (e.g., "IT,FR,DE")
        if [[ ! "$ALLOWED_COUNTRIES" =~ ^[A-Za-z,]+$ ]]; then
            die "Country codes must be letters and comma-separated (e.g., IT,fr,DE)"
        fi
    fi
    # Validate provider using a robust glob match
    if ! [[ " $ALLOWED_PROVIDERS " == *"$GEO_IP_PROVIDER"* ]]; then
        die "Invalid provider '$GEO_IP_PROVIDER'. Allowed providers are: $ALLOWED_PROVIDERS"
    fi
    log "INFO" "Using Geo-IP provider: $GEO_IP_PROVIDER"
}

###################
# System & Network Checks
###################

# Check for internet connectivity before attempting downloads
check_connectivity() {
    log "INFO" "Checking connectivity..."
    for site in "${CONNECTIVITY_CHECK_SITES[@]}"; do
        if ping -c 1 -W 5 "$site" &>/dev/null; then
            log "INFO" "Connectivity check passed with $site"
            return 0
        fi
    done
    die "Connectivity check failed. Please check network connection."
}

# Detects the best available firewall backend (nftables or iptables)
detect_backend() {
    log "INFO" "Detecting firewall backend..."
    if command -v nft &>/dev/null; then
        FIREWALL_BACKEND="nftables"
        REQUIRED_COMMANDS=(curl iprange ping nft)
        log "INFO" "Backend selected: nftables (native)"

        # Pre-flight check: Verify nftables functionality
        # This catches issues like missing kernel modules or permission errors early.
        if ! nft list tables >/dev/null 2>&1; then
             die "nftables detected but 'nft list tables' failed. Check kernel support or permissions."
        fi

    elif command -v iptables &>/dev/null && command -v ipset &>/dev/null; then
        FIREWALL_BACKEND="iptables"
        # Dynamically add IPv6 tools only if needed
        REQUIRED_COMMANDS=(curl ipset iptables iprange ping iptables-restore)
        if [[ "$GEOBLOCK_IPV6" == true ]]; then
             REQUIRED_COMMANDS+=(ip6tables ip6tables-restore)
        fi
        log "INFO" "Backend selected: iptables (legacy)"
    else
        die "No supported firewall backend found. Need 'nft' or 'iptables'/'ipset'."
    fi
}

# Verify that all dynamically required commands are installed
check_installed_commands() {
    local missing_commands=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd")
    done
    [[ ${#missing_commands[@]} -eq 0 ]] || die "Missing commands: ${missing_commands[*]}"
}

retry_command() {
    local retries=0
    local command=("$@")

    while ((retries < MAX_RETRIES)); do
        # Use an 'if' statement to prevent 'set -e' from exiting the script
        # if the command fails, allowing the loop to handle the error.
        if "${command[@]}"; then
            return 0 # Success
        fi

        ((retries++))
        log "WARN" "Command failed: ${command[*]}. Retry $retries/$MAX_RETRIES"
        sleep $((2 ** retries)) # 1s, 2s, 4s, 8s...
    done

    die "Command failed after $MAX_RETRIES retries: ${command[*]}"
}

# Helper to expand interface wildcards (e.g. "eth0 br-*")
expand_interfaces() {
    local input_patterns="$1"
    local -a expanded_list=()

    for pattern in $input_patterns; do
        if [[ "$pattern" == *"*"* ]]; then
            # Expand wildcard using /sys/class/net
            # Expand wildcard using compgen to avoid SC2206
            local matches=()
            if mapfile -t matches < <(compgen -G "/sys/class/net/$pattern"); then
                : # Matches found
            fi

            for match in "${matches[@]}"; do
                expanded_list+=("$(basename "$match")")
            done
        else
            # Literal interface
            if [[ -d "/sys/class/net/$pattern" ]]; then
                expanded_list+=("$pattern")
            else
                log "WARN" "Interface '$pattern' not found, skipping."
            fi
        fi
    done

    # Deduplicate and join with commas
    if [[ ${#expanded_list[@]} -gt 0 ]]; then
        printf "%s\n" "${expanded_list[@]}" | sort -u | tr '\n' ',' | sed 's/,$//'
    fi
}

###################
# List Generation
###################

# Download and process blocklists
# Download and process blocklists
download_blocklists() {
    log "INFO" "Downloading blocklists..."

    # Export functions so they are available in the subshells
    # launched with '&' for parallel downloads.
    export -f retry_command
    export -f die
    export -f log

    local max_jobs=8
    local urls=()

    # 1. Download and parse remote git index (v4 lists)
    retry_command curl -fsSL --connect-timeout 10 --max-time 30 "$BLOCK_LIST_URL" -o "$BLOCK_LIST_FILE_NAME" ||
        die "Failed to download block list index"

    while IFS= read -r line; do
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        line=$(echo "$line" | tr -d '\r')
        urls+=("$line")
    done < "$BLOCK_LIST_FILE_NAME"

    # 2. Parse Unified Manual List (v4/v6/hybrid)
    if [[ -f "$MANUAL_BLOCK_LIST" ]]; then
        log "INFO" "Adding manual blocklists from $MANUAL_BLOCK_LIST"
        while IFS= read -r line; do
            [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
            line=$(echo "$line" | tr -d '\r')
            urls+=("$line")
        done < "$MANUAL_BLOCK_LIST"
    else
         log "WARN" "Manual blocklist file not found: $MANUAL_BLOCK_LIST. Proceeding with repo lists only."
    fi

    # 3. Download ALL Lists to the main block list directory
    cd "$BLOCK_LIST_DIR" || die "Failed to change directory to $BLOCK_LIST_DIR"
    rm -f ./*

    log "INFO" "Dispatching ${#urls[@]} downloads..."

    for url in "${urls[@]}"; do
        # Wait for a job to finish if we are at the max
        while (($(jobs -p | wc -l) >= max_jobs)); do
            wait -n || true
        done

        (
            log "INFO" "Downloading: $url"
            # Use -f to fail on HTTP errors (404/500) so we don't save error pages
            # Use timeouts to prevent hanging indefinitely
            curl -fsSL -OJ --connect-timeout 15 --max-time 90 "$url" || log "WARN" "Failed to download $url"
        ) &
    done
    wait || true

    log "INFO" "Blocklist download complete."
    cd "$SCRIPT_DIR" # Go back to base dir
}

# Pre-process downloaded lists to separate v4 and v6 content
# This prevents iprange from misinterpreting IPv6 addresses as DNS names
separate_ip_families() {
    log "INFO" "Separating IPv4 and IPv6 addresses from raw blocklists..."
    
    # Enable nullglob to handle empty dirs
    shopt -s nullglob
    local raw_files=("$BLOCK_LIST_DIR"/*)
    shopt -u nullglob

    if [[ ${#raw_files[@]} -eq 0 ]]; then
        log "WARN" "No blocklist files found to process."
        return
    fi

    # Create directories for clean lists if they don't exist (using temp dir structure)
    local v4_clean_dir="$TEMP_DIR/clean_v4"
    local v6_clean_dir="$TEMP_DIR/clean_v6"
    mkdir -p "$v4_clean_dir" "$v6_clean_dir"

    # Regex patterns - Anchored to start of line to avoid partial matches in text/HTML
    # IPv4: Start with optional whitespace, then IP.
    local ipv4_regex='^[[:space:]]*([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?'
    # IPv6: Start with optional whitespace, then hex/colon.
    local ipv6_regex='^[[:space:]]*[0-9a-fA-F:]+(/[0-9]{1,3})?'

    log "INFO" "Processing ${#raw_files[@]} files..."
    
    for file in "${raw_files[@]}"; do
        local filename
        filename=$(basename "$file")

        # Sanity Check: validation for HTML/XML content (e.g. Captive Portal / 404 Page)
        # We check the first 20 lines for common HTML tags.
        if head -n 20 "$file" | grep -qilE "<!DOCTYPE|<html|<head|<body"; then
             log "WARN" "File '$filename' appears to be HTML/XML (invalid content). Skipping."
             continue
        fi
        
        # Extract IPv4 -> clean_v4/filename.v4
        # We use explicit grep to find ONLY valid-looking v4 lines
        grep -E "$ipv4_regex" "$file" | grep -v ":" > "$v4_clean_dir/$filename.v4" &

        # Extract IPv6 -> clean_v6/filename.v6
        if [[ "$GEOBLOCK_IPV6" == true ]]; then
             grep -E "$ipv6_regex" "$file" | grep ":" > "$v6_clean_dir/$filename.v6" &
        fi
    done
    wait
    
    # Update global pointers/variables or move files back? 
    # Better to point the generator to these clean dirs.
    BLOCK_LIST_CLEAN_V4_DIR="$v4_clean_dir"
    BLOCK_LIST_CLEAN_V6_DIR="$v6_clean_dir"
    
    log "INFO" "Separation complete."
}

# Generate the final, optimized IP list files
generate_ip_list() {
    log "INFO" "Generating optimized IP range lists..."

    [[ -f "$COUNTRY_IPS_DOWNLOADER" && -x "$COUNTRY_IPS_DOWNLOADER" ]] || die "$COUNTRY_IPS_DOWNLOADER script not found/executable"

    # Define our optimizer command for IPv4.
    # --ipset-reduce is best for ipset and works well for nft.
    local IPRANGE_OPTIMIZER_CMD=(iprange --ipset-reduce 20)

    # Run the downloader script to get .list.v4 and .list.v6 files
    local downloader_countries_arg
    if [[ "$ALLOWED_COUNTRIES" == *":"* ]]; then
        log "INFO" "Downloading country IPs using advanced provider syntax: $ALLOWED_COUNTRIES"
        downloader_countries_arg="$ALLOWED_COUNTRIES"
    else
        log "INFO" "Downloading country IPs for: $ALLOWED_COUNTRIES (using default provider $GEO_IP_PROVIDER)"
        downloader_countries_arg="$GEO_IP_PROVIDER:$ALLOWED_COUNTRIES"
    fi
    retry_command "$COUNTRY_IPS_DOWNLOADER" -c "$downloader_countries_arg"

    cd "$IP_LIST_DIR" || die "Failed to change directory to $IP_LIST_DIR"

    # --- Optimize IPv4 List ---
    # We now look at ALLOW lists (glob) AND the Cleaned Blocklists (dir content)
    
    local v4_files=("$ALLOW_LIST_DIR"/*.v4)
    local v4_block_files=()
    
    if [[ "$USE_BLOCKLIST" == true && -n "$BLOCK_LIST_CLEAN_V4_DIR" ]]; then
        # Separate function populated BLOCK_LIST_CLEAN_V4_DIR
        shopt -s nullglob
        v4_block_files=("$BLOCK_LIST_CLEAN_V4_DIR"/*)
        shopt -u nullglob
    fi

    if [[ ${#v4_block_files[@]} -gt 0 ]]; then
        log "INFO" "Optimizing IPv4 allow lists and subtracting ${#v4_block_files[@]} blocklists."
        "${IPRANGE_OPTIMIZER_CMD[@]}" "${v4_files[@]}" --except "${v4_block_files[@]}" >"$IP_RANGE_FILE_V4"
    else
        log "INFO" "Optimizing IPv4 allow lists (no blocklist)."
        "${IPRANGE_OPTIMIZER_CMD[@]}" "${v4_files[@]}" >"$IP_RANGE_FILE_V4"
    fi

    # CRITICAL safety check
    [[ -s "$IP_RANGE_FILE_V4" ]] || die "IPv4 range file $IP_RANGE_FILE_V4 not found or empty. Aborting."
    log "INFO" "IPv4 range list created at $IP_RANGE_FILE_V4"

    # --- Generate IPv6 List (with cat + sort) ---
    if [[ "$GEOBLOCK_IPV6" == true ]]; then
        log "INFO" "Combining and de-duplicating IPv6 allow lists..."

        # Use nullglob to safely handle cases where no .v6 files exist.
        shopt -s nullglob
        local v6_files=("$ALLOW_LIST_DIR"/*.v6)
        shopt -u nullglob

        if [[ ${#v6_files[@]} -gt 0 ]]; then
            # iprange does not support IPv6.
            # We concatenate, strip comments/whitespace, and sort unique.
            grep -h -vE '^\s*#|^\s*$' "${v6_files[@]}" | sed 's/#.*//' | tr -d '\r' | sort -u > "$IP_RANGE_FILE_V6"
        else
            # No files found, create an empty file
            true > "$IP_RANGE_FILE_V6"
        fi

        if [[ ! -s "$IP_RANGE_FILE_V6" ]]; then
             log "WARN" "IPv6 range file $IP_RANGE_FILE_V6 is empty. IPv6 Geo-IP will not be active."
        else
             log "INFO" "IPv6 range list created at $IP_RANGE_FILE_V6"
             if [[ "$USE_BLOCKLIST" == true && -n "$BLOCK_LIST_CLEAN_V6_DIR" ]]; then
                 # Use cleaned v6 block files
                 shopt -s nullglob
                 local v6_block_files=("$BLOCK_LIST_CLEAN_V6_DIR"/*)
                 shopt -u nullglob
                 
                 if [[ ${#v6_block_files[@]} -gt 0 ]]; then
                     log "INFO" "Generating IPv6 blocklist from ${#v6_block_files[@]} files..."
                     # Files are already grep-filtered for content, just strip comments (# or ;) /join
                     grep -h -vE '^\s*#|^\s*$' "${v6_block_files[@]}" | sed 's/[#;].*//' | tr -d '\r' | sort -u > "$IP_RANGE_FILE_BLOCK_V6"
                     log "INFO" "IPv6 blocklist created at $IP_RANGE_FILE_BLOCK_V6"
                 else
                     log "INFO" "No blocklist files found (Blocklists enabled but clean dir empty)."
                fi
             else
                 if [[ "$USE_BLOCKLIST" == true ]]; then
                    log "INFO" "No blocklist files to process."
                 fi
             fi
        fi
    else
        log "INFO" "IPv6 Geo-blocking is disabled (Default). Skipping v6 list generation."
        # Ensure we don't leave stale files if the user toggled the flag
        rm -f "$IP_RANGE_FILE_V6"
    fi

    cd "$SCRIPT_DIR" # Go back to base dir
}

###############################################################################
#
# FIREWALL BACKEND: IPTABLES
#
###############################################################################

# Helper to create/populate an ipset (v4 or v6)
populate_ipset() {
    local set_name="$1"
    local range_file="$2"
    local family="$3"
    local set_cmd="ipset"

    log "INFO" "Configuring $set_cmd set '$set_name'..."

    # Create or flush the set
    if $set_cmd -n -q list "$set_name" &>/dev/null; then
        $set_cmd flush "$set_name"
    else
        $set_cmd create "$set_name" hash:net family "$family" || die "Failed to create $set_cmd set $set_name"
    fi

    # Use ipset restore for high-performance loading
    local IPSET_RESTORE_FILE="$TEMP_DIR/$set_name.ipset.restore"
    echo "create $set_name hash:net family $family -exist" > "$IPSET_RESTORE_FILE"
    echo "flush $set_name" >> "$IPSET_RESTORE_FILE"

    while IFS= read -r line; do
        echo "add $set_name $line" >> "$IPSET_RESTORE_FILE"
    done <"$range_file"

    $set_cmd restore < "$IPSET_RESTORE_FILE" || die "Failed to restore $set_cmd set"
    log "INFO" "$set_cmd set '$set_name' populated."
}

# Apply all firewall rules using the legacy iptables backend
# Apply all firewall rules using the legacy iptables backend
apply_rules_iptables() {
    log "INFO" "Applying rules using iptables/ipset backend..."

    # Clean up native nftables table (if it exists) to prevent conflict
    log "INFO" "Cleaning up native nftables table (if any)..."
    nft delete table inet $NFT_TABLE_NAME 2>/dev/null || true

    # 1. Populate IPv4 ipset
    populate_ipset "$ALLOW_LIST_NAME_V4" "$IP_RANGE_FILE_V4" "inet"

    # 2. Cleanup Old Rules (Mangle + Filter + NAT)
    log "INFO" "Cleaning up old iptables rules and chains..."

    # Remove jumps from system chains FIRST
    # We use 'while' loops to ensure we remove multiple instances if they exist
    while iptables -t mangle -D PREROUTING -j LABO_PREROUTING 2>/dev/null; do :; done
    while iptables -D INPUT -j LABO_INPUT 2>/dev/null; do :; done
    while iptables -D DOCKER-USER -j LABO_DOCKER_USER 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -j LABO_POSTROUTING 2>/dev/null; do :; done

    # Flush and Delete custom chains
    iptables -t mangle -F LABO_PREROUTING 2>/dev/null || true
    iptables -t mangle -X LABO_PREROUTING 2>/dev/null || true

    iptables -t filter -F LABO_INPUT 2>/dev/null || true
    iptables -t filter -X LABO_INPUT 2>/dev/null || true

    iptables -t filter -F LABO_DOCKER_USER 2>/dev/null || true
    iptables -t filter -X LABO_DOCKER_USER 2>/dev/null || true

    iptables -t nat -F LABO_POSTROUTING 2>/dev/null || true
    iptables -t nat -X LABO_POSTROUTING 2>/dev/null || true

    # 3. Apply IPv4 Rules (Atomic Restore)
    # We use *mangle for PREROUTING (Gatekeeper) and *filter for INPUT/FORWARD protection.
    local IPTABLES_RULES_FILE="$TEMP_DIR/iptables.rules"
    cat > "$IPTABLES_RULES_FILE" <<-EOF
*mangle
:LABO_PREROUTING - [0:0]

# --- LABO_PREROUTING Chain (Gatekeeper) ---
# Equivalent to nftables 'prerouting' hook.
# Filters traffic BEFORE routing decisions.

# 1. Drop Invalid
-A LABO_PREROUTING -m state --state INVALID -j DROP

# 2. Optimization: Accept Established/Related immediately
-A LABO_PREROUTING -m state --state RELATED,ESTABLISHED -j ACCEPT

# 3. Critical System & Local Traffic
-A LABO_PREROUTING -i lo -j ACCEPT
# In iptables, '+' is the wildcard (equivalent to '*' in nft/shell)
-A LABO_PREROUTING -i docker0 -j ACCEPT
-A LABO_PREROUTING -i br+ -j ACCEPT
# WireGuard interfaces (inner traffic)
-A LABO_PREROUTING -i wg+ -j ACCEPT

# 4. Accept Private Networks (Bypass GeoIP)
-A LABO_PREROUTING -s 10.0.0.0/8 -j ACCEPT
-A LABO_PREROUTING -s 172.16.0.0/12 -j ACCEPT
-A LABO_PREROUTING -s 192.168.0.0/16 -j ACCEPT

# 5. Geo-IP Filter (DROP)
# Drop NEW traffic not in allowlist
-A LABO_PREROUTING -m set ! --match-set $ALLOW_LIST_NAME_V4 src -j DROP

# 6. Default: Accept (Pass to next table)
-A LABO_PREROUTING -j ACCEPT
COMMIT

*filter
:LABO_INPUT - [0:0]
:LABO_DOCKER_USER - [0:0]

# --- LABO_INPUT Chain (Host Protection) ---
# Traffic has already passed GeoIP in mangle table.

-A LABO_INPUT -m state --state INVALID -j DROP
-A LABO_INPUT -i lo -j ACCEPT
-A LABO_INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A LABO_INPUT -s 10.0.0.0/8 -j ACCEPT
-A LABO_INPUT -s 172.16.0.0/12 -j ACCEPT
-A LABO_INPUT -s 192.168.0.0/16 -j ACCEPT
-A LABO_INPUT -p icmp -j ACCEPT

# Trust local interfaces
-A LABO_INPUT -i docker0 -j ACCEPT
-A LABO_INPUT -i br+ -j ACCEPT
# Trust WireGuard interfaces
-A LABO_INPUT -i wg+ -j ACCEPT

# SSH Brute Force Mitigation (IPv4)
-A LABO_INPUT -p tcp --dport $SSH_PORT -m state --state NEW -m recent --set --name SSH --rsource
-A LABO_INPUT -p tcp --dport $SSH_PORT -m state --state NEW -m recent --update --seconds 10 --hitcount 10 --name SSH --rsource -j LOG --log-prefix "SSH BRUTE DROP: "
-A LABO_INPUT -p tcp --dport $SSH_PORT -m state --state NEW -m recent --update --seconds 10 --hitcount 10 --name SSH --rsource -j DROP
-A LABO_INPUT -j ACCEPT

# --- LABO_DOCKER_USER Chain (Forwarding) ---
# Protects Docker containers.
# Mirrors the 'FORWARD' chain logic in nftables.

-A LABO_DOCKER_USER -m state --state INVALID -j DROP
-A LABO_DOCKER_USER -m state --state RELATED,ESTABLISHED -j RETURN

# Explicitly trust Docker interfaces (using '+' wildcard)
-A LABO_DOCKER_USER -i docker0 -j RETURN
-A LABO_DOCKER_USER -o docker0 -j RETURN
-A LABO_DOCKER_USER -i br+ -j RETURN
-A LABO_DOCKER_USER -o br+ -j RETURN
# Explicitly trust WireGuard interfaces
-A LABO_DOCKER_USER -i wg+ -j RETURN
-A LABO_DOCKER_USER -o wg+ -j RETURN

# Private Nets & Loopback
-A LABO_DOCKER_USER -i lo -j RETURN
-A LABO_DOCKER_USER -s 10.0.0.0/8 -j RETURN
-A LABO_DOCKER_USER -s 172.16.0.0/12 -j RETURN
-A LABO_DOCKER_USER -s 192.168.0.0/16 -j RETURN

# Note: GeoIP dropping happened in 'mangle' table.
# If we reached here, the packet is valid or established.
-A LABO_DOCKER_USER -j RETURN
COMMIT

*nat
:LABO_POSTROUTING - [0:0]

# --- LABO_POSTROUTING Chain (Masquerade) ---
-A LABO_POSTROUTING -o eth+ -j MASQUERADE
-A LABO_POSTROUTING -o en+ -j MASQUERADE
COMMIT
EOF

    # Apply Rules
    iptables-restore --noflush < "$IPTABLES_RULES_FILE" || die "Failed to apply iptables rules"

    # Hook into system chains
    iptables -t mangle -I PREROUTING 1 -j LABO_PREROUTING
    iptables -I INPUT 1 -j LABO_INPUT
    iptables -I DOCKER-USER 1 -j LABO_DOCKER_USER
    iptables -t nat -I POSTROUTING 1 -j LABO_POSTROUTING

    log "INFO" "iptables (IPv4) rules applied successfully."

    # 4. Handle IPv6 (ip6tables)
    if [[ "$GEOBLOCK_IPV6" == true ]]; then
        log "INFO" "Applying ip6tables (IPv6) rules..."
        if [[ -s "$IP_RANGE_FILE_V6" ]]; then
            populate_ipset "$ALLOW_LIST_NAME_V6" "$IP_RANGE_FILE_V6" "inet6"

            if [[ -s "$IP_RANGE_FILE_BLOCK_V6" ]]; then
                populate_ipset "$BLOCK_LIST_NAME_V6" "$IP_RANGE_FILE_BLOCK_V6" "inet6"
            fi

            # Cleanup IPv6
            log "INFO" "Cleaning up old ip6tables rules..."
            while ip6tables -t mangle -D PREROUTING -j LABO_PREROUTING_V6 2>/dev/null; do :; done
            while ip6tables -D INPUT -j LABO_INPUT_V6 2>/dev/null; do :; done
            while ip6tables -D DOCKER-USER -j LABO_DOCKER_USER_V6 2>/dev/null; do :; done

            ip6tables -t mangle -F LABO_PREROUTING_V6 2>/dev/null || true
            ip6tables -t mangle -X LABO_PREROUTING_V6 2>/dev/null || true

            ip6tables -t filter -F LABO_INPUT_V6 2>/dev/null || true
            ip6tables -t filter -X LABO_INPUT_V6 2>/dev/null || true

            ip6tables -t filter -F LABO_DOCKER_USER_V6 2>/dev/null || true
            ip6tables -t filter -X LABO_DOCKER_USER_V6 2>/dev/null || true

            local IP6TABLES_RULES_FILE="$TEMP_DIR/ip6tables.rules"
            cat > "$IP6TABLES_RULES_FILE" <<-EOF
*mangle
:LABO_PREROUTING_V6 - [0:0]

# --- LABO_PREROUTING_V6 (Gatekeeper) ---
-A LABO_PREROUTING_V6 -m state --state INVALID -j DROP
-A LABO_PREROUTING_V6 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A LABO_PREROUTING_V6 -i lo -j ACCEPT
-A LABO_PREROUTING_V6 -i docker0 -j ACCEPT
-A LABO_PREROUTING_V6 -i br+ -j ACCEPT
-A LABO_PREROUTING_V6 -i wg+ -j ACCEPT

# Accept Private & Multicast
-A LABO_PREROUTING_V6 -s fe80::/10 -j ACCEPT
-A LABO_PREROUTING_V6 -s fc00::/7 -j ACCEPT
-A LABO_PREROUTING_V6 -s ff00::/8 -j ACCEPT

# CRITICAL: ICMPv6 must be accepted before GeoIP
-A LABO_PREROUTING_V6 -p icmpv6 -j ACCEPT

# Blocklist IPv6 (Drop)
EOF
            if [[ -s "$IP_RANGE_FILE_BLOCK_V6" ]]; then
               echo "-A LABO_PREROUTING_V6 -m set --match-set $BLOCK_LIST_NAME_V6 src -j DROP" >> "$IP6TABLES_RULES_FILE"
            fi
            cat >> "$IP6TABLES_RULES_FILE" <<-EOF

# Geo-IP Filter (DROP)
-A LABO_PREROUTING_V6 -m set ! --match-set $ALLOW_LIST_NAME_V6 src -j DROP

-A LABO_PREROUTING_V6 -j ACCEPT
COMMIT

*filter
:LABO_INPUT_V6 - [0:0]
:LABO_DOCKER_USER_V6 - [0:0]

# --- LABO_INPUT_V6 ---
-A LABO_INPUT_V6 -m state --state INVALID -j DROP
-A LABO_INPUT_V6 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A LABO_INPUT_V6 -i lo -j ACCEPT
-A LABO_INPUT_V6 -s fe80::/10 -j ACCEPT
-A LABO_INPUT_V6 -p icmpv6 -j ACCEPT
-A LABO_INPUT_V6 -i wg+ -j ACCEPT

# SSH Rate Limit (IPv6)
-A LABO_INPUT_V6 -p tcp --dport $SSH_PORT -m hashlimit --hashlimit-name ssh_v6_limit --hashlimit-mode srcip --hashlimit-above 10/second -j LOG --log-prefix "IP6 SSH RATE-DROP: "
-A LABO_INPUT_V6 -p tcp --dport $SSH_PORT -m hashlimit --hashlimit-name ssh_v6_limit --hashlimit-mode srcip --hashlimit-above 10/second -j DROP
-A LABO_INPUT_V6 -j ACCEPT

# --- LABO_DOCKER_USER_V6 ---
-A LABO_DOCKER_USER_V6 -m state --state INVALID -j DROP
-A LABO_DOCKER_USER_V6 -m state --state RELATED,ESTABLISHED -j RETURN
-A LABO_DOCKER_USER_V6 -i lo -j RETURN
-A LABO_DOCKER_USER_V6 -i docker0 -j RETURN
-A LABO_DOCKER_USER_V6 -o docker0 -j RETURN
-A LABO_DOCKER_USER_V6 -i br+ -j RETURN
-A LABO_DOCKER_USER_V6 -o br+ -j RETURN
-A LABO_DOCKER_USER_V6 -i wg+ -j RETURN
-A LABO_DOCKER_USER_V6 -o wg+ -j RETURN
-A LABO_DOCKER_USER_V6 -s fe80::/10 -j RETURN
-A LABO_DOCKER_USER_V6 -j RETURN
COMMIT
EOF
            ip6tables-restore --noflush < "$IP6TABLES_RULES_FILE" || die "Failed to apply ip6tables rules"

            ip6tables -t mangle -I PREROUTING 1 -j LABO_PREROUTING_V6
            ip6tables -I INPUT 1 -j LABO_INPUT_V6
            ip6tables -I DOCKER-USER 1 -j LABO_DOCKER_USER_V6

            log "INFO" "ip6tables (IPv6) rules applied successfully."
        else
            log "WARN" "IPv6 range file is empty. Skipping IPv6 rule application."
        fi
    else
        # Flush if IPv6 GeoBlocking is disabled but backend is iptables
        if command -v ip6tables &>/dev/null; then
             log "INFO" "Flushing IPv6 rules (Geo-blocking disabled)..."
             while ip6tables -t mangle -D PREROUTING -j LABO_PREROUTING_V6 2>/dev/null; do :; done
             while ip6tables -D INPUT -j LABO_INPUT_V6 2>/dev/null; do :; done
             while ip6tables -D DOCKER-USER -j LABO_DOCKER_USER_V6 2>/dev/null; do :; done

             ip6tables -t mangle -F LABO_PREROUTING_V6 2>/dev/null || true
             ip6tables -t mangle -X LABO_PREROUTING_V6 2>/dev/null || true
             ip6tables -t filter -F LABO_INPUT_V6 2>/dev/null || true
             ip6tables -t filter -X LABO_INPUT_V6 2>/dev/null || true
             ip6tables -t filter -F LABO_DOCKER_USER_V6 2>/dev/null || true
             ip6tables -t filter -X LABO_DOCKER_USER_V6 2>/dev/null || true
        fi
    fi
}

###############################################################################
#
# FIREWALL BACKEND: NFTABLES
#
###############################################################################

# Apply all firewall rules using the modern nftables backend
apply_rules_nftables() {
    log "INFO" "Applying rules using nftables (native) backend..."

    # --- Clean up legacy iptables rules ---
    # This prevents conflicts if switching from iptables to nftables.
    if command -v iptables &>/dev/null; then
        log "INFO" "Cleaning up legacy iptables rules..."
        # Remove jumps from system chains
        while iptables -t mangle -D PREROUTING -j LABO_PREROUTING 2>/dev/null; do :; done
        while iptables -D INPUT -j LABO_INPUT 2>/dev/null; do :; done
        while iptables -D DOCKER-USER -j LABO_DOCKER_USER 2>/dev/null; do :; done

        # Flush and delete custom chains
        iptables -t mangle -F LABO_PREROUTING 2>/dev/null || true
        iptables -t mangle -X LABO_PREROUTING 2>/dev/null || true

        iptables -F LABO_INPUT 2>/dev/null || true
        iptables -X LABO_INPUT 2>/dev/null || true

        iptables -F LABO_DOCKER_USER 2>/dev/null || true
        iptables -X LABO_DOCKER_USER 2>/dev/null || true
    fi
    if command -v ip6tables &>/dev/null; then
        log "INFO" "Cleaning up legacy ip6tables rules..."
        while ip6tables -t mangle -D PREROUTING -j LABO_PREROUTING_V6 2>/dev/null; do :; done
        while ip6tables -D INPUT -j LABO_INPUT_V6 2>/dev/null; do :; done
        while ip6tables -D DOCKER-USER -j LABO_DOCKER_USER_V6 2>/dev/null; do :; done

        ip6tables -t mangle -F LABO_PREROUTING_V6 2>/dev/null || true
        ip6tables -t mangle -X LABO_PREROUTING_V6 2>/dev/null || true

        ip6tables -F LABO_INPUT_V6 2>/dev/null || true
        ip6tables -X LABO_INPUT_V6 2>/dev/null || true

        ip6tables -F LABO_DOCKER_USER_V6 2>/dev/null || true
        ip6tables -X LABO_DOCKER_USER_V6 2>/dev/null || true
    fi

    # --- Prepare sets (Stream-based approach) ---
    # We write the comma-separated elements to temp files instead of variables
    # to avoid "Argument list too long" or memory issues with massive lists.
    # This allows us to handle lists of any size (e.g., full continents).

    local v4_elements_file="$TEMP_DIR/v4_elements.nft"
    if [[ -s "$IP_RANGE_FILE_V4" ]]; then
        # Convert newlines to commas, remove trailing comma
        tr '\n' ',' < "$IP_RANGE_FILE_V4" | sed 's/,$//' > "$v4_elements_file"
    else
        log "WARN" "IPv4 range file is empty. Using dummy IP."
        echo "192.0.2.1" > "$v4_elements_file" # RFC 5737 TEST-NET-1
    fi

    local v6_elements_file="$TEMP_DIR/v6_elements.nft"
    local v6_block_elements_file="$TEMP_DIR/v6_block_elements.nft"
    if [[ "$GEOBLOCK_IPV6" == true ]]; then
        # Process Allowlist
        if [[ -s "$IP_RANGE_FILE_V6" ]]; then
            # Filter valid IPv6 chars only (hex, colon, slash) and join
            grep -E '^[0-9a-fA-F:/]+$' "$IP_RANGE_FILE_V6" | tr '\n' ',' | sed 's/,$//' > "$v6_elements_file" || true
        fi
        
        # Verify Allowlist is not empty (after filtering), fallback if needed
        if [[ ! -s "$v6_elements_file" ]]; then
            log "WARN" "IPv6 allowlist is empty (or containing only invalid entries). Using dummy IP."
            echo "2001:db8::1" > "$v6_elements_file"  # RFC 3849 documentation prefix
        fi

        # Process Blocklist
        if [[ -s "$IP_RANGE_FILE_BLOCK_V6" ]]; then
             # Filter valid IPv6 chars only (hex, colon, slash) and join
            grep -E '^[0-9a-fA-F:/]+$' "$IP_RANGE_FILE_BLOCK_V6" | tr '\n' ',' | sed 's/,$//' > "$v6_block_elements_file" || true
        fi
    fi

    # --- Generate atomic ruleset ---
    log "INFO" "Generating atomic nftables ruleset..."
    log "INFO" "Flushing existing $NFT_TABLE_NAME table..."
    nft delete table inet $NFT_TABLE_NAME 2>/dev/null || true

    # We construct the config stream dynamically to inject the files.
    # This subshell outputs the entire valid NFTables configuration.
    (
        cat <<EOF
        table inet $NFT_TABLE_NAME {
            # ========= SETS =========
            # These sets contain our whitelisted IPs.

            set private_nets_v4 {
                type ipv4_addr; flags interval; auto-merge;
                elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }
            }
            set private_nets_v6 {
                type ipv6_addr; flags interval; auto-merge;
                elements = { fc00::/7, fe80::/10, ff00::/8 }
            }
            set $ALLOW_LIST_NAME_V4 {
                type ipv4_addr; flags interval; auto-merge;
                elements = {
EOF
        # Inject IPv4 elements directly from the file stream
        cat "$v4_elements_file"

        cat <<EOF
                }
            }

            # Dynamic sets for SSH brute-force (v4 + v6) using meters (more efficient)
            set ssh_meter_v4 { type ipv4_addr; flags dynamic; size 65536; }
            set ssh_meter_v6 { type ipv6_addr; flags dynamic; size 65536; }
EOF

        # Conditionally inject IPv6 set only if enabled
        if [[ "$GEOBLOCK_IPV6" == true ]]; then
            cat <<EOF
            set $ALLOW_LIST_NAME_V6 {
                type ipv6_addr; flags interval; auto-merge;
                elements = {
EOF
            cat "$v6_elements_file"
            cat <<EOF
                }
            }
EOF
            if [[ -s "$v6_block_elements_file" ]]; then
                cat <<EOF
            set $BLOCK_LIST_NAME_V6 {
                type ipv6_addr; flags interval; auto-merge;
                elements = {
EOF
                cat "$v6_block_elements_file"
                cat <<EOF
                }
            }
EOF
            fi
        fi

        # --- Flowtable Definition ---
        local ft_devs=""
        if [[ -n "$FLOWTABLE_INTERFACES" ]]; then
            ft_devs=$(expand_interfaces "$FLOWTABLE_INTERFACES")
            if [[ -n "$ft_devs" ]]; then
                log "INFO" "Enabling Flowtable (Fasttrack) on interfaces: $ft_devs"
                cat <<EOF
            flowtable f {
                hook ingress priority 0;
                devices = { $ft_devs };
            }
EOF
            else
                log "WARN" "No valid interfaces found for Flowtable (after expansion). Skipping."
            fi
        fi

        cat <<EOF
            # ========= CHAINS =========

            # --- PREROUTING Chain (Main Gatekeeper) ---
            # Filters *ALL* incoming traffic (Host + Forward) at the earliest point.
            # Priority -2 (Mangle) is chosen to drop bad traffic BEFORE connection tracking (priority -200)
            # or other expensive operations, saving CPU.
            chain GEOIP_PREROUTING {
                type filter hook prerouting priority mangle -2; policy accept;

                # 1. Accept critical system/stateful traffic immediately.
                #    'lo' is loopback (localhost).
                #    'established,related' allows return traffic for connections we initiated.
                iifname "lo" accept
                ct state established,related accept
                ct state invalid counter drop

                # 2. Accept private networks (Docker, WG, LAN) to bypass Geo-IP.
                #    This prevents locking ourselves out of local management.
                ip saddr @private_nets_v4 accept
                ip6 saddr @private_nets_v6 accept

                # 3. CRITICAL: Allow all ICMPv6 *before* geo-blocking.
                #    This is required for Neighbor Discovery (NDP) to work.
                #    Blocking this breaks IPv6 connectivity completely.
                ip6 nexthdr icmpv6 accept

                # 4. Geo-IP v4 Filter (DROP)
                #    Drop all NEW traffic that is NOT in the allowlist.
                #    We use a 'set' for O(1) performance regardless of list size.
                ip saddr != @$ALLOW_LIST_NAME_V4 counter log prefix "PREROUTING GEO-DROP: " drop

                # 5. Geo-IP v6 Filter (DROP, if enabled)
EOF
        if [[ "$GEOBLOCK_IPV6" == true ]]; then
             if [[ -s "$v6_block_elements_file" ]]; then
                 echo '                ip6 saddr @'"$BLOCK_LIST_NAME_V6"' counter log prefix "PREROUTING6 BLOCK-DROP: " drop'
             fi
            echo '                ip6 nexthdr != icmpv6 ip6 saddr != @'"$ALLOW_LIST_NAME_V6"' counter log prefix "PREROUTING6 GEO-DROP: " drop'
        fi
        cat <<EOF
            }

            # --- FORWARD Chain (Flowtable Offload) ---
            # Handles traffic passing THROUGH the box (e.g., to Docker containers).
            chain FORWARD {
                type filter hook forward priority filter; policy accept;
EOF
        if [[ -n "$ft_devs" ]]; then
             echo '                # Offload established connections to flowtable'
             echo '                # This bypasses the classic Linux network stack for high throughput.'
             echo '                ip protocol { tcp, udp } flow offload @f'
        fi
        cat <<EOF

                # Optimization: Accept established/related traffic immediately.
                # This saves CPU cycles by avoiding rule evaluation for every packet in the stream.
                ct state established,related accept

                # Docker Integration: Explicitly accept traffic on Docker interfaces.
                # Although the policy is accept, explicit rules ensure traffic flow regardless
                # of future policy changes or interactions with Docker's own chains.
                # Added WireGuard (wg*) support for VPN traffic forwarding.
                iifname { "lo", "docker0" } accept
                iifname "wg*" accept
                iifname "br-*" accept
                oifname "docker0" accept
                oifname "wg*" accept
                oifname "br-*" accept
            }

            # --- INPUT Chain (Host Protection) ---
            # Handles traffic *to* this server that has *already passed* PREROUTING.
            # We use 'policy accept' because the main filter is done.
            chain INPUT {
                type filter hook input priority filter - 10; policy accept;

                # 1. Drop invalid packets (redundant but safe).
                ct state invalid counter drop

                # 2. Optimization: Accept established/related traffic immediately.
                #    This avoids checking SSH rules for every packet of an active session.
                ct state related,established accept

                # 3. Optimization: Accept private networks (LAN/Docker/WireGuard) immediately.
                #    This aligns with iptables logic and prevents LAN lockouts/rate-limiting.
                ip saddr @private_nets_v4 accept
                ip6 saddr @private_nets_v6 accept
                # Trust local interfaces and WireGuard
                iifname { "lo", "docker0" } accept
                iifname "wg*" accept
                iifname "br-*" accept

                # 4. SSH Brute Force Mitigation (v4) - Optimized with Dynamic Set
                #    If IP exceeds 10/second, it is dropped.
                tcp dport $SSH_PORT ct state new update @ssh_meter_v4 { ip saddr limit rate over 10/second } counter log prefix "INPUT SSH RATE-DROP: " drop

                # 5. SSH Brute Force Mitigation (v6) - Optimized with Dynamic Set
                tcp dport $SSH_PORT ct state new update @ssh_meter_v6 { ip6 saddr limit rate over 10/second } counter log prefix "INPUT6 SSH RATE-DROP: " drop
            }

            # --- POSTROUTING Chain (NAT) ---
            chain POSTROUTING {
                type nat hook postrouting priority srcnat; policy accept;
                oifname "eth*" masquerade
                oifname "en*" masquerade
            }  
        }
EOF
    ) | nft -f -
    # Note: -o (optimize) is intentionally omitted because it conflicts with 'auto-merge'
    # and causes "File exists" errors. 'auto-merge' combined with 'iprange' already
    # ensures the sets are optimized in the kernel.

    log "INFO" "nftables ruleset applied successfully."
}

###################
# Main Logic
###################
main() {
    # 1. Check root, create secure temp dir, and setup traps
    setup_temp_dir_and_traps

    # 2. Parse -c, -p, -b, -G, -s flags
    parse_arguments "$@"

    # 3. Check internet (fail-fast)
    check_connectivity

    # 4. Detect nftables vs iptables (must be *after* parse_arguments)
    detect_backend

    # 5. Check if required commands are installed
    check_installed_commands

    # 6. Create directories
    mkdir -p "$ALLOW_LIST_DIR" "$BLOCK_LIST_DIR" || die "Failed to create directories"

    # 7. Download v4 blocklists if -b is used
    if [[ "$USE_BLOCKLIST" == true ]]; then
        download_blocklists
        separate_ip_families
    fi

    # 8. Download country lists and generate final v4/v6 range files
    # This step is critical. It calls the retry_command, and
    # generate_ip_list() itself will 'die' if the final list is empty.
    generate_ip_list

    # 9. Dispatch to the correct firewall function
    if [[ "$FIREWALL_BACKEND" == "nftables" ]]; then
        apply_rules_nftables
    elif [[ "$FIREWALL_BACKEND" == "iptables" ]]; then
        apply_rules_iptables
    else
        die "Internal error: No valid firewall backend determined."
    fi

    log "INFO" "Configuration completed successfully."
}

# Pass all command-line arguments to the main function
main "$@"