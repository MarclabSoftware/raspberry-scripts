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
# - Default Deny Policy: Secures the host (INPUT) while safely filtering
#   Docker traffic (FORWARD) before Docker's own rules.
# - Protection: Robust SSH rate-limiting (v4/v6) and IPv4 blocklist support.
# - Safe & Atomic: Applies rules in a single transaction to prevent errors.
# - Robust: Includes connectivity checks, download retries, and error trapping.
#
# Usage:
#   sudo ./ip-blocker.sh [-c COUNTRIES] [-p PROVIDER] [-b] [-G] [-s SSH_PORT] [-i INTERFACES] [-h]
#
# Options:
#   -c countries   Specify allowed countries.
#                  Simple: "IT,DE,FR" (uses provider from -f -p).
#                  Advanced: "ripe:IT,FR;ipdeny:CN;nirsoft:KR,IT" (ignores -p).
#   -p provider    Geo-IP provider: 'ipdeny', 'ripe', 'nirsoft' (default: ipdeny)
#   -b             Enable (IPv4) blocklists.
#   -G             Enable Geo-blocking for IPv6 (default: false, IPv6 is allowed).
#   -s sshPort     Specify the SSH port (default: 22).
#   -i interfaces  List of interfaces for Flowtable offload (e.g. "eth0 wg0").
#   -h             Display this help message.
#
# Author: LaboDJ
# Version: 5.1
# Last Updated: 2025/11/15
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
# Our main table name for nftables
declare -r NFT_TABLE_NAME="labo_firewall"
# Names for our sets/ipsets
declare -r ALLOW_LIST_NAME_V4="allowlist_v4"
declare -r ALLOW_LIST_NAME_V6="allowlist_v6"
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

declare CLEANUP_REGISTERED=false
declare FIREWALL_BACKEND=""
declare -a REQUIRED_COMMANDS=()

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
    -i interfaces  Interfaces for Flowtable offload (e.g. "eth0 wg0")
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
download_blocklists() {
    log "INFO" "Downloading blocklists..."

    # Export functions so they are available in the subshells
    # launched with '&' for parallel downloads.
    export -f retry_command
    export -f die
    export -f log

    retry_command curl -sSL "$BLOCK_LIST_URL" -o "$BLOCK_LIST_FILE_NAME" ||
        die "Failed to download block list index"

    cd "$BLOCK_LIST_DIR" || die "Failed to change directory to $BLOCK_LIST_DIR"
    rm -f ./*

    local urls
    mapfile -t urls <"$BLOCK_LIST_FILE_NAME"

    # This logic checks job count *before* launching a new job,
    # which is more robust with 'set -e'.
    local max_jobs=8
    for url in "${urls[@]}"; do
        # Skip empty lines or comments
        [[ -z "$url" || "${url:0:1}" == "#" ]] && continue

        # Wait for a job to finish if we are at the max
        # '|| true' prevents 'set -e' from exiting if a job fails
        while (($(jobs -p | wc -l) >= max_jobs)); do
            wait -n || true
        done

        # Launch the download in a subshell
        (
            log "INFO" "Downloading: $url"
            # -OJ: Write output to a local file named like the remote file
            retry_command curl -sSL -OJ "$url" || die "Failed to download $url"
        ) &
    done

    # Wait for all remaining jobs
    wait || true

    log "INFO" "Blocklist download complete."
    cd "$SCRIPT_DIR" # Go back to base dir
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

    # --- Generate IPv4 List (with iprange) ---
    # Use a glob that finds all .v4 files (e.g., it.ripe.list.v4, manual.v4)
    local v4_files=("$ALLOW_LIST_DIR"/*.v4)
    if [[ "$USE_BLOCKLIST" == true && -n "$(ls -A "$BLOCK_LIST_DIR")" ]]; then
        log "INFO" "Optimizing IPv4 allow lists (reduce mode) and subtracting blocklists."
        "${IPRANGE_OPTIMIZER_CMD[@]}" "${v4_files[@]}" --except "$BLOCK_LIST_DIR"/* >"$IP_RANGE_FILE_V4"
    else
        log "INFO" "Optimizing IPv4 allow lists (reduce mode, no blocklist)."
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
            # We concatenate all lists and use 'sort -u' to de-duplicate.
            cat "${v6_files[@]}" | sort -u > "$IP_RANGE_FILE_V6"
        else
            # No files found, create an empty file
            true > "$IP_RANGE_FILE_V6"
        fi

        if [[ ! -s "$IP_RANGE_FILE_V6" ]]; then
             log "WARN" "IPv6 range file $IP_RANGE_FILE_V6 is empty. IPv6 Geo-IP will not be active."
        else
             log "INFO" "IPv6 range list created at $IP_RANGE_FILE_V6"
             if [[ "$USE_BLOCKLIST" == true ]]; then
                log "WARN" "Blocklists (-b) are NOT applied to IPv6 rules."
             fi
        fi
    else
        log "INFO" "IPv6 Geo-blocking is disabled. Skipping v6 list generation."
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
apply_rules_iptables() {
    log "INFO" "Applying rules using iptables/ipset backend..."

    # Clean up native nftables table (if it exists)
    log "INFO" "Cleaning up native nftables table (if any)..."
    nft delete table inet $NFT_TABLE_NAME 2>/dev/null || true

    # 1. Populate IPv4 ipset
    populate_ipset "$ALLOW_LIST_NAME_V4" "$IP_RANGE_FILE_V4" "inet"

    # 2. Create/Flush our custom chains
    log "INFO" "Creating/Flushing custom iptables chains..."
    iptables -N LOG_AND_DROP_INPUT 2>/dev/null || iptables -F LOG_AND_DROP_INPUT
    iptables -N LOG_AND_DROP_DOCKER 2>/dev/null || iptables -F LOG_AND_DROP_DOCKER
    iptables -N LABO_INPUT 2>/dev/null || iptables -F LABO_INPUT
    iptables -N LABO_DOCKER_USER 2>/dev/null || iptables -F LABO_DOCKER_USER

    # 3. Remove old rules
    log "INFO" "Cleaning up old rules from INPUT and DOCKER-USER chains..."
    # Use 'while' loops to remove all existing instances of our rules
    while iptables -D INPUT -j LABO_INPUT 2>/dev/null; do :; done
    while iptables -D DOCKER-USER -j LABO_DOCKER_USER 2>/dev/null; do :; done
    while iptables -D INPUT -m set ! --match-set $ALLOW_LIST_NAME_V4 src -j LOG_AND_DROP_INPUT 2>/dev/null; do :; done
    while iptables -D DOCKER-USER -m set ! --match-set $ALLOW_LIST_NAME_V4 src -j LOG_AND_DROP_DOCKER 2>/dev/null; do :; done
    while iptables -D INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --set --name SSH --rsource 2>/dev/null; do :; done
    while iptables -D INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --update --seconds 10 --hitcount 10 --name SSH --rsource -j LOG --log-prefix "SSH BRUTE DROP: " 2>/dev/null; do :; done
    while iptables -D INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --update --seconds 10 --hitcount 10 --name SSH --rsource -j DROP 2>/dev/null; do :; done
    while iptables -D INPUT -m state --state INVALID -j DROP 2>/dev/null; do :; done
    while iptables -D INPUT -i lo -j ACCEPT 2>/dev/null; do :; done
    while iptables -D INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    while iptables -D DOCKER-USER -m state --state INVALID -j DROP 2>/dev/null; do :; done
    while iptables -D DOCKER-USER -i lo -j RETURN 2>/dev/null; do :; done
    while iptables -D DOCKER-USER -m state --state RELATED,ESTABLISHED -j RETURN 2>/dev/null; do :; done
    log "INFO" "Cleanup of old rules complete."

    # 4. Populate logging chains
    iptables -A LOG_AND_DROP_INPUT -j LOG --log-level 4 --log-prefix "INPUT DROP: "
    iptables -A LOG_AND_DROP_INPUT -j DROP
    iptables -A LOG_AND_DROP_DOCKER -j LOG --log-level 4 --log-prefix "DOCKER DROP: "
    iptables -A LOG_AND_DROP_DOCKER -j DROP

    # 5. Apply IPv4 rules using iptables-restore
    local IPTABLES_RULES_FILE="$TEMP_DIR/iptables.rules"
    cat > "$IPTABLES_RULES_FILE" <<-EOF
*filter
:LABO_INPUT - [0:0]
:LABO_DOCKER_USER - [0:0]

# --- LABO_INPUT Chain (Host Protection) ---
# Base rules: allow traffic that is always safe
-A LABO_INPUT -m state --state INVALID -j DROP
-A LABO_INPUT -i lo -j ACCEPT
-A LABO_INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A LABO_INPUT -s 10.0.0.0/8 -j ACCEPT
-A LABO_INPUT -s 172.16.0.0/12 -j ACCEPT
-A LABO_INPUT -s 192.168.0.0/16 -j ACCEPT
# Drop traffic NOT from our Geo-IP list.
# This applies only to NEW, non-private traffic.
-A LABO_INPUT -m set ! --match-set $ALLOW_LIST_NAME_V4 src -j LOG_AND_DROP_INPUT
-A LABO_INPUT -p icmp -j ACCEPT
# SSH Brute Force Mitigation (IPv4)
-A LABO_INPUT -p tcp --dport $SSH_PORT -m state --state NEW -m recent --set --name SSH --rsource
-A LABO_INPUT -p tcp --dport $SSH_PORT -m state --state NEW -m recent --update --seconds 10 --hitcount 10 --name SSH --rsource -j LOG --log-prefix "SSH BRUTE DROP: "
-A LABO_INPUT -p tcp --dport $SSH_PORT -m state --state NEW -m recent --update --seconds 10 --hitcount 10 --name SSH --rsource -j DROP
-A LABO_INPUT -j ACCEPT

# --- LABO_DOCKER_USER Chain (Forwarded Traffic Protection) ---
# This chain's logic was already correct.
-A LABO_DOCKER_USER -m state --state INVALID -j DROP
-A LABO_DOCKER_USER -i lo -j RETURN
-A LABO_DOCKER_USER -s 10.0.0.0/8 -j RETURN
-A LABO_DOCKER_USER -s 172.16.0.0/12 -j RETURN
-A LABO_DOCKER_USER -s 192.168.0.0/16 -j RETURN
-A LABO_DOCKER_USER -m state --state RELATED,ESTABLISHED -j RETURN
# Geo-IP Filter: Drop NEW traffic not in our allowlist
-A LABO_DOCKER_USER -m set ! --match-set $ALLOW_LIST_NAME_V4 src -j LOG_AND_DROP_DOCKER
# Default Allow: Return to Docker's chains
-A LABO_DOCKER_USER -j RETURN
COMMIT
EOF

    iptables-restore --noflush < "$IPTABLES_RULES_FILE" || die "Failed to apply iptables rules"

    # 6. Insert jumps to our new, clean chains
    iptables -I INPUT 1 -j LABO_INPUT
    iptables -I DOCKER-USER 1 -j LABO_DOCKER_USER

    log "INFO" "iptables (IPv4) rules applied successfully."

    # 7. Handle IPv6
    if [[ "$GEOBLOCK_IPV6" == true ]]; then
        log "INFO" "Applying ip6tables (IPv6) rules..."
        if [[ -s "$IP_RANGE_FILE_V6" ]]; then
            populate_ipset "$ALLOW_LIST_NAME_V6" "$IP_RANGE_FILE_V6" "inet6"

            ip6tables -N LABO_INPUT_V6 2>/dev/null || ip6tables -F LABO_INPUT_V6
            ip6tables -N LABO_DOCKER_USER_V6 2>/dev/null || ip6tables -F LABO_DOCKER_USER_V6

            local IP6TABLES_RULES_FILE="$TEMP_DIR/ip6tables.rules"
            cat > "$IP6TABLES_RULES_FILE" <<-EOF
*filter
:LABO_INPUT_V6 - [0:0]
:LABO_DOCKER_USER_V6 - [0:0]

# --- LABO_INPUT_V6 Chain (Host Protection) ---
-A LABO_INPUT_V6 -m state --state INVALID -j DROP
-A LABO_INPUT_V6 -i lo -j ACCEPT
-A LABO_INPUT_V6 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A LABO_INPUT_V6 -s fe80::/10 -j ACCEPT
-A LABO_INPUT_V6 -s fc00::/7 -j ACCEPT
# Log and Drop non-allowlisted Geo-IP traffic
-A LABO_INPUT_V6 -m set ! --match-set $ALLOW_LIST_NAME_V6 src -j DROP
-A LABO_INPUT_V6 -p icmpv6 -j ACCEPT
# SSH Brute Force Mitigation (IPv6, rate-limit only)
-A LABO_INPUT_V6 -p tcp --dport $SSH_PORT -m hashlimit --hashlimit-name ssh_v6_limit --hashlimit-mode srcip --hashlimit-above 10/second -j LOG --log-prefix "IP6 SSH RATE-DROP: "
-A LABO_INPUT_V6 -p tcp --dport $SSH_PORT -m hashlimit --hashlimit-name ssh_v6_limit --hashlimit-mode srcip --hashlimit-above 10/second -j DROP
-A LABO_INPUT_V6 -j ACCEPT

# --- LABO_DOCKER_USER_V6 Chain (Forwarded Traffic Protection) ---
-A LABO_DOCKER_USER_V6 -m state --state INVALID -j DROP
-A LABO_DOCKER_USER_V6 -i lo -j RETURN
-A LABO_DOCKER_USER_V6 -s fe80::/10 -j RETURN
-A LABO_DOCKER_USER_V6 -s fc00::/7 -j RETURN
-A LABO_DOCKER_USER_V6 -m state --state RELATED,ESTABLISHED -j RETURN
# Geo-IP Filter: Drop traffic not in our allowlist
-A LABO_DOCKER_USER_V6 -m set ! --match-set $ALLOW_LIST_NAME_V6 src -j DROP
# Default Allow: Return to Docker's chains
-A LABO_DOCKER_USER_V6 -j RETURN
COMMIT
EOF
            ip6tables-restore --noflush < "$IP6TABLES_RULES_FILE" || die "Failed to apply ip6tables rules"

            ip6tables -D INPUT -j LABO_INPUT_V6 2>/dev/null || true
            ip6tables -I INPUT 1 -j LABO_INPUT_V6

            ip6tables -D DOCKER-USER -j LABO_DOCKER_USER_V6 2>/dev/null || true
            ip6tables -I DOCKER-USER 1 -j LABO_DOCKER_USER_V6

            log "INFO" "ip6tables (IPv6) rules applied successfully."
        else
            log "WARN" "IPv6 range file is empty. Skipping IPv6 rule application."
        fi
    else
        log "INFO" "IPv6 Geo-blocking disabled. Checking if ip6tables is installed to flush rules..."
        if command -v ip6tables &>/dev/null; then
            log "INFO" "ip6tables found. Flushing our custom chains to ensure IPv6 is open."
            ip6tables -D INPUT -j LABO_INPUT_V6 2>/dev/null || true
            ip6tables -D DOCKER-USER -j LABO_DOCKER_USER_V6 2>/dev/null || true
            ip6tables -F LABO_INPUT_V6 2>/dev/null || true
            ip6tables -F LABO_DOCKER_USER_V6 2>/dev/null || true
            ip6tables -X LABO_INPUT_V6 2>/dev/null || true
            ip6tables -X LABO_DOCKER_USER_V6 2>/dev/null || true
        else
            log "INFO" "ip6tables not found, skipping v6 flush."
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
        iptables -D INPUT -j LABO_INPUT 2>/dev/null || true
        iptables -D DOCKER-USER -j LABO_DOCKER_USER 2>/dev/null || true
        iptables -F LABO_INPUT 2>/dev/null || true
        iptables -F LABO_DOCKER_USER 2>/dev/null || true
        iptables -X LABO_INPUT 2>/dev/null || true
        iptables -X LABO_DOCKER_USER 2>/dev/null || true
    fi
    if command -v ip6tables &>/dev/null; then
        log "INFO" "Cleaning up legacy ip6tables rules..."
        ip6tables -D INPUT -j LABO_INPUT_V6 2>/dev/null || true
        ip6tables -D DOCKER-USER -j LABO_DOCKER_USER_V6 2>/dev/null || true
        ip6tables -F LABO_INPUT_V6 2>/dev/null || true
        ip6tables -F LABO_DOCKER_USER_V6 2>/dev/null || true
        ip6tables -X LABO_INPUT_V6 2>/dev/null || true
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
    if [[ "$GEOBLOCK_IPV6" == true ]]; then
        if [[ -s "$IP_RANGE_FILE_V6" ]]; then
            tr '\n' ',' < "$IP_RANGE_FILE_V6" | sed 's/,$//' > "$v6_elements_file"
        else
            log "WARN" "IPv6 range file is empty. Using dummy IP."
            echo "2001:db8::1" > "$v6_elements_file"  # RFC 3849 documentation prefix
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
                elements = { fc00::/7, fe80::/10 }
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
            chain GEOIP_PREROUTING {
                type filter hook prerouting priority mangle -2; policy accept;

                # 1. Accept critical system/stateful traffic immediately.
                iifname "lo" accept
                ct state established,related accept
                ct state invalid counter drop

                # 2. Accept private networks (Docker, WG, LAN) to bypass Geo-IP.
                ip saddr @private_nets_v4 accept
                ip6 saddr @private_nets_v6 accept

                # 3. CRITICAL: Allow all ICMPv6 *before* geo-blocking.
                #    This is required for Neighbor Discovery (NDP) to work.
                ip6 nexthdr icmpv6 accept

                # 4. Geo-IP v4 Filter (DROP)
                #    Drop all NEW traffic that is NOT in the allowlist.
                ip saddr != @$ALLOW_LIST_NAME_V4 counter log prefix "PREROUTING GEO-DROP: " drop

                # 5. Geo-IP v6 Filter (DROP, if enabled)
EOF
        if [[ "$GEOBLOCK_IPV6" == true ]]; then
            echo '                ip6 nexthdr != icmpv6 ip6 saddr != @'"$ALLOW_LIST_NAME_V6"' counter log prefix "PREROUTING6 GEO-DROP: " drop'
        fi
        cat <<EOF
            }

            # --- FORWARD Chain (Flowtable Offload) ---
            chain FORWARD {
                type filter hook forward priority filter; policy accept;
EOF
        if [[ -n "$ft_devs" ]]; then
             echo '                # Offload established connections to flowtable'
             echo '                ip protocol { tcp, udp } flow offload @f'
        fi
        cat <<EOF
            }

            # --- INPUT Chain (Host Protection) ---
            # Handles traffic *to* this server that has *already passed* PREROUTING.
            # We use 'policy accept' because the main filter is done.
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

                # 3. Optimization: Accept private networks (LAN/Docker) immediately.
                #    This aligns with iptables logic and prevents LAN lockouts/rate-limiting.
                ip saddr @private_nets_v4 accept
                ip6 saddr @private_nets_v6 accept
                iifname "lo" accept

                # 4. SSH Brute Force Mitigation (v4) - Optimized with Meter
                #    If IP exceeds 10/second, it is dropped.
                tcp dport $SSH_PORT ct state new meter ssh_meter_v4 { ip saddr limit rate over 10/second } counter log prefix "INPUT SSH RATE-DROP: " drop

                # 5. SSH Brute Force Mitigation (v6) - Optimized with Meter
                tcp dport $SSH_PORT ct state new meter ssh_meter_v6 { ip6 saddr limit rate over 10/second } counter log prefix "INPUT6 SSH RATE-DROP: " drop
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
    $USE_BLOCKLIST && download_blocklists

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