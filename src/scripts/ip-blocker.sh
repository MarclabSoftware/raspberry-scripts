#!/usr/bin/env bash

###############################################################################
# IP-Based Firewall Configuration Script
#
# This script configures a sophisticated, hybrid-backend firewall.
# It automatically detects the optimal firewall (nftables or iptables)
# and applies rules for Geo-IP filtering, brute-force mitigation, and
# internal network protection.
#
# Features:
# - Automatic Backend Detection: Natively uses 'nftables' if available,
#   otherwise falls back to 'iptables' and 'ipset'.
# - Hybrid IPv4/IPv6 Support: Provides full Geo-IP filtering for IPv4 and
#   optional, opt-in Geo-IP filtering for IPv6.
# - Private Network Whitelist: Hardcoded rules prevent blocking RFC1918
#   (LAN) and Docker internal traffic.
# - Manual List Support: Automatically includes any user-created '*.v4'
#   or '*.v6' files from the 'lists/allow' directory.
# - SSH Brute Force Mitigation: Implements a robust rate-limit and temporary
#   ban mechanism for incoming SSH connections.
# - Docker Protection: Applies Geo-IP rules to Docker's 'forward' chain
#   before Docker's own rules, protecting containers.
# - Atomic & Safe: Applies all rules at once (atomically) to prevent
#   a broken firewall state.
# - Efficient: Uses 'iprange' to pre-calculate and optimize the final
#   allowlist, minimizing per-packet CPU load.
# - Robust: Includes connectivity checks, downloader retries with
#   exponential backoff, and full error trapping.
#
# Usage:
#   sudo ./ip-blocker-v4.sh [-c COUNTRIES] [-b] [-G] [-s SSH_PORT] [-h]
#
# Options:
#   -c countries   Comma-separated list of allowed countries (e.g., IT,FR,DE)
#   -b             Enable (IPv4) blocklists.
#   -G             Enable Geo-blocking for IPv6 (default: false, IPv6 is allowed).
#   -s sshPort     Specify the SSH port (default: 22).
#   -h             Display this help message.
#
# Requirements:
#   - Root privileges (sudo)
#   - curl, iprange, ping
#   - Backend: 'nft' OR 'iptables', 'ipset' (and 'ip6tables', 'ip6set' if -G is used)
#   - Active internet connection (for list downloads)
#
# Author: LaboDJ
# Version: 4.0
# Last Updated: 2025/11/10
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
declare -r COUNTRY_IPS_DOWNLOADER="$SCRIPT_DIR/country_ips_downloader_ipdeny.sh"
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
# Final optimized IP list files
declare -r IP_RANGE_FILE_V4="/tmp/$ALLOW_LIST_NAME_V4.iprange.txt"
declare -r IP_RANGE_FILE_V6="/tmp/$ALLOW_LIST_NAME_V6.iprange.txt"
# Max retries for downloader
declare -r MAX_RETRIES=10
# Sites to test connectivity
declare -r CONNECTIVITY_CHECK_SITES=(github.com google.com)

###################
# Global Variables
###################

# These variables are set by parse_arguments()
declare ALLOWED_COUNTRIES="$DEFAULT_COUNTRIES"
declare USE_BLOCKLIST=false
declare SSH_PORT=22
declare GEOBLOCK_IPV6=false # Default: IPv6 is NOT geo-blocked
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

# Cleanup temporary files on script exit
cleanup() {
    if [[ "$CLEANUP_REGISTERED" == true ]]; then
        log "INFO" "Performing cleanup..."
        # Remove the final generated range files
        rm -f "$IP_RANGE_FILE_V4" "$IP_RANGE_FILE_V6"
    fi
}

# Check for root privileges and setup traps
check_root() {
    [[ "${EUID:-$(id -u)}" -ne 0 ]] && die "Please run as root/sudo"
    setup_signal_handlers
}

###################
# Argument Parsing
###################

# Display usage information
print_usage() {
    cat <<EOF

Usage: $0 [-c countries] [-b] [-G] [-s sshPort] [-h]

Options:
    -c countries   Specify allowed countries (comma-separated, e.g., IT,DE,FR)
    -b             Enable block lists (Applies to IPv4 only by default)
    -G             Enable Geo-blocking for IPv6 (default: false)
    -s sshPort     Specify SSH port (default: 22)
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

    # New loop includes '-G' and removes '-6'
    while getopts ":c:bs:hG" opt; do
        case $opt in
        c) ALLOWED_COUNTRIES="$OPTARG" ;;
        b) USE_BLOCKLIST=true ;;
        G) GEOBLOCK_IPV6=true ;; # Set IPv6 blocking to opt-in
        s) SSH_PORT="$OPTARG" ;;
        h) print_usage ;;
        \?) log "ERROR" "Invalid option: -$OPTARG"; print_usage ;;
        :) log "ERROR" "The option -$OPTARG requires an argument"; print_usage ;;
        esac
    done

    # Validate SSH port is a valid number
    if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        die "SSH port must be a number between 1 and 65535"
    fi
    # Validate country codes
    if [[ ! "$ALLOWED_COUNTRIES" =~ ^[A-Z,]+$ ]]; then
        die "Country codes must be uppercase and comma-separated (e.g., IT,FR,DE)"
    fi
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
             REQUIRED_COMMANDS+=(ip6set ip6tables ip6tables-restore)
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

# Retry a given command with exponential backoff
retry_command() {
    local retries=0
    local command=("$@")

    while ((retries < MAX_RETRIES)); do
        "${command[@]}" && return 0
        ((retries++))
        log "WARN" "Command failed: ${command[*]}. Retry $retries/$MAX_RETRIES"
        sleep $((2 ** retries)) # 1s, 2s, 4s, 8s...
    done
    die "Command failed after $MAX_RETRIES retries: ${command[*]}"
}

###################
# List Generation
###################

# Download and process blocklists
download_blocklists() {
    log "INFO" "Downloading blocklists..."
    
    # --- Export functions ---
    # We must export functions so they are available in the subshells
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
            # -OJ is correct as confirmed by v1 script
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

    # Run the downloader script to get .list.v4 and .list.v6 files
    log "INFO" "Downloading country IPs for: $ALLOWED_COUNTRIES"
    retry_command "$COUNTRY_IPS_DOWNLOADER" -c "$ALLOWED_COUNTRIES"

    cd "$IP_LIST_DIR" || die "Failed to change directory to $IP_LIST_DIR"

    # --- Generate IPv4 List ---
    # Use a glob that finds all .v4 files.
    # This includes '*.list.v4' (downloaded) and 'manual.v4' (user-created).
    local v4_files=("$ALLOW_LIST_DIR"/*.v4)
    if [[ "$USE_BLOCKLIST" == true && -n "$(ls -A "$BLOCK_LIST_DIR")" ]]; then
        log "INFO" "Optimizing IPv4 allow lists and subtracting blocklists."
        iprange --optimize "${v4_files[@]}" --except "$BLOCK_LIST_DIR"/* >"$IP_RANGE_FILE_V4"
    else
        log "INFO" "Optimizing IPv4 allow lists (no blocklist)."
        iprange --optimize "${v4_files[@]}" >"$IP_RANGE_FILE_V4"
    fi
    [[ -s "$IP_RANGE_FILE_V4" ]] || die "IPv4 range file $IP_RANGE_FILE_V4 not found or empty. Aborting."
    log "INFO" "IPv4 range list created at $IP_RANGE_FILE_V4"

    # --- Generate IPv6 List (Only if -G flag is used) ---
    if [[ "$GEOBLOCK_IPV6" == true ]]; then
        log "INFO" "Combining IPv6 allow lists (skipping iprange optimization due to old version)..."

        # Use a glob that finds all .v6 files.
        # This includes '*.list.v6' and 'manual.v6'.
        # We use 'cat' to bypass the old iprange v1.0.4, which
        # does not support IPv6 and tries to DNS-resolve the addresses.
        cat "$ALLOW_LIST_DIR"/*.v6 > "$IP_RANGE_FILE_V6" 2>/dev/null || true

        if [[ ! -s "$IP_RANGE_FILE_V6" ]]; then
             log "WARN" "IPv6 range file $IP_RANGE_FILE_V6 is empty. IPv6 Geo-IP will not be active."
        else
             log "INFO" "IPv6 range list created at $IP_RANGE_FILE_V6"
             if [[ "$USE_BLOCKLIST" == true ]]; then
                log "WARN" "Blocklists (-b) are NOT applied to IPv6 rules (iprange version limitation)."
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
    # (Questa funzione è corretta, la lasciamo invariata)
    local set_name="$1"
    local range_file="$2"
    local family="$3"
    local set_cmd="ipset"
    if [[ "$family" == "inet6" ]]; then
        set_cmd="ip6set"
    fi
    log "INFO" "Configuring $set_cmd set '$set_name'..."
    if $set_cmd -n -q list "$set_name" &>/dev/null; then
        $set_cmd flush "$set_name"
    else
        $set_cmd create "$set_name" hash:net family "$family" || die "Failed to create $set_cmd set $set_name"
    fi
    local IPSET_RESTORE_FILE="/tmp/$set_name.ipset.restore"
    echo "create $set_name hash:net family $family -exist" > "$IPSET_RESTORE_FILE"
    echo "flush $set_name" >> "$IPSET_RESTORE_FILE"
    while IFS= read -r line; do
        echo "add $set_name $line" >> "$IPSET_RESTORE_FILE"
    done <"$range_file"
    $set_cmd restore < "$IPSET_RESTORE_FILE" || die "Failed to restore $set_cmd set"
    rm -f "$IPSET_RESTORE_FILE"
    log "INFO" "$set_cmd set '$set_name' populated."
}

apply_rules_iptables() {
    log "INFO" "Applying rules using iptables/ipset backend..."

    # Clean up native nftables table (if it exists)
    log "INFO" "Cleaning up native nftables table (if any)..."
    nft delete table inet $NFT_TABLE_NAME 2>/dev/null || true

    # 1. Populate IPv4 ipset
    populate_ipset "$ALLOW_LIST_NAME_V4" "$IP_RANGE_FILE_V4" "inet"

    # Create/Flush our custom chains
    log "INFO" "Creating/Flushing custom iptables chains..."
    iptables -N LOG_AND_DROP_INPUT 2>/dev/null || iptables -F LOG_AND_DROP_INPUT
    iptables -N LOG_AND_DROP_DOCKER 2>/dev/null || iptables -F LOG_AND_DROP_DOCKER
    iptables -N LABO_INPUT 2>/dev/null || iptables -F LABO_INPUT
    iptables -N LABO_DOCKER_USER 2>/dev/null || iptables -F LABO_DOCKER_USER

    # --- Remove old rules ---
    log "INFO" "Cleaning up old rules from INPUT and DOCKER-USER chains..."
    # Rimuovi i jump (vecchi e nuovi)
    while iptables -D INPUT -j LABO_INPUT 2>/dev/null; do :; done
    while iptables -D DOCKER-USER -j LABO_DOCKER_USER 2>/dev/null; do :; done
    
    # Rimuovi le vecchie regole del Geo-IP
    while iptables -D INPUT -m set ! --match-set $ALLOW_LIST_NAME_V4 src -j LOG_AND_DROP_INPUT 2>/dev/null; do :; done
    while iptables -D DOCKER-USER -m set ! --match-set $ALLOW_LIST_NAME_V4 src -j LOG_AND_DROP_DOCKER 2>/dev/null; do :; done
    
    # Rimuovi TUTTE le vecchie regole SSH (questo era il bug)
    while iptables -D INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --set --name SSH --rsource 2>/dev/null; do :; done
    while iptables -D INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --update --seconds 10 --hitcount 10 --name SSH --rsource -j LOG --log-prefix "SSH BRUTE DROP: " 2>/dev/null; do :; done
    while iptables -D INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --update --seconds 10 --hitcount 10 --name SSH --rsource -j DROP 2>/dev/null; do :; done
    
    # Rimuovi altre vecchie regole
    while iptables -D INPUT -m state --state INVALID -j DROP 2>/dev/null; do :; done
    while iptables -D INPUT -i lo -j ACCEPT 2>/dev/null; do :; done
    while iptables -D INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    while iptables -D DOCKER-USER -m state --state INVALID -j DROP 2>/dev/null; do :; done
    while iptables -D DOCKER-USER -i lo -j RETURN 2>/dev/null; do :; done
    while iptables -D DOCKER-USER -m state --state RELATED,ESTABLISHED -j RETURN 2>/dev/null; do :; done
    
    log "INFO" "Cleanup of old rules complete."

    # 2. Populate logging chains
    iptables -A LOG_AND_DROP_INPUT -j LOG --log-level 4 --log-prefix "INPUT DROP: "
    iptables -A LOG_AND_DROP_INPUT -j DROP
    iptables -A LOG_AND_DROP_DOCKER -j LOG --log-level 4 --log-prefix "DOCKER DROP: "
    iptables -A LOG_AND_DROP_DOCKER -j DROP

    # 3. Apply IPv4 rules using iptables-restore to our custom chains
    local IPTABLES_RULES_FILE="/tmp/iptables.rules"
    cat > "$IPTABLES_RULES_FILE" <<-EOF
*filter
:LABO_INPUT - [0:0]
:LABO_DOCKER_USER - [0:0]
-A LABO_INPUT -m state --state INVALID -j DROP
-A LABO_INPUT -i lo -j ACCEPT
-A LABO_INPUT -s 10.0.0.0/8 -j ACCEPT
-A LABO_INPUT -s 172.16.0.0/12 -j ACCEPT
-A LABO_INPUT -s 192.168.0.0/16 -j ACCEPT
-A LABO_INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A LABO_INPUT -p tcp --dport $SSH_PORT -m state --state NEW -m recent --set --name SSH --rsource
-A LABO_INPUT -p tcp --dport $SSH_PORT -m state --state NEW -m recent --update --seconds 10 --hitcount 10 --name SSH --rsource -j LOG --log-prefix "SSH BRUTE DROP: "
-A LABO_INPUT -p tcp --dport $SSH_PORT -m state --state NEW -m recent --update --seconds 10 --hitcount 10 --name SSH --rsource -j DROP
-A LABO_INPUT -m set ! --match-set $ALLOW_LIST_NAME_V4 src -j LOG_AND_DROP_INPUT
-A LABO_INPUT -j RETURN
-A LABO_DOCKER_USER -m state --state INVALID -j DROP
-A LABO_DOCKER_USER -i lo -j RETURN
-A LABO_DOCKER_USER -s 10.0.0.0/8 -j RETURN
-A LABO_DOCKER_USER -s 172.16.0.0/12 -j RETURN
-A LABO_DOCKER_USER -s 192.168.0.0/16 -j RETURN
-A LABO_DOCKER_USER -m state --state RELATED,ESTABLISHED -j RETURN
-A LABO_DOCKER_USER -m set ! --match-set $ALLOW_LIST_NAME_V4 src -j LOG_AND_DROP_DOCKER
-A LABO_DOCKER_USER -j RETURN
COMMIT
EOF

    iptables-restore --noflush < "$IPTABLES_RULES_FILE" || die "Failed to apply iptables rules"
    rm -f "$IPTABLES_RULES_FILE"

    # Inserisci i jump alle nostre catene pulite
    iptables -I INPUT 1 -j LABO_INPUT
    iptables -I DOCKER-USER 1 -j LABO_DOCKER_USER

    log "INFO" "iptables (IPv4) rules applied successfully."

    # 4. Handle IPv6 (Questa logica è corretta)
    if [[ "$GEOBLOCK_IPV6" == true ]]; then
        # ... (Questa logica è già idempotente, non serve modificarla) ...
        log "INFO" "Applying ip6tables (IPv6) rules..."
        if [[ -s "$IP_RANGE_FILE_V6" ]]; then
            populate_ipset "$ALLOW_LIST_NAME_V6" "$IP_RANGE_FILE_V6" "inet6"
            
            ip6tables -N LABO_INPUT_V6 2>/dev/null || ip6tables -F LABO_INPUT_V6
            ip6tables -N LABO_DOCKER_USER_V6 2>/dev/null || ip6tables -F LABO_DOCKER_USER_V6
            
            local IP6TABLES_RULES_FILE="/tmp/ip6tables.rules"
            cat > "$IP6TABLES_RULES_FILE" <<-EOF
*filter
:LABO_INPUT_V6 - [0:0]
:LABO_DOCKER_USER_V6 - [0:0]
-A LABO_INPUT_V6 -m state --state INVALID -j DROP
-A LABO_INPUT_V6 -i lo -j ACCEPT
-A LABO_INPUT_V6 -s fe80::/10 -j ACCEPT
-A LABO_INPUT_V6 -s fc00::/7 -j ACCEPT
-A LABO_INPUT_V6 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A LABO_INPUT_V6 -m set ! --match-set $ALLOW_LIST_NAME_V6 src -j DROP
-A LABO_INPUT_V6 -j RETURN
-A LABO_DOCKER_USER_V6 -m state --state INVALID -j DROP
-A LABO_DOCKER_USER_V6 -i lo -j RETURN
-A LABO_DOCKER_USER_V6 -s fe80::/10 -j RETURN
-A LABO_DOCKER_USER_V6 -s fc00::/7 -j RETURN
-A LABO_DOCKER_USER_V6 -m state --state RELATED,ESTABLISHED -j RETURN
-A LABO_DOCKER_USER_V6 -m set ! --match-set $ALLOW_LIST_NAME_V6 src -j DROP
-A LABO_DOCKER_USER_V6 -j RETURN
COMMIT
EOF
            ip6tables-restore --noflush < "$IP6TABLES_RULES_FILE" || die "Failed to apply ip6tables rules"
            rm -f "$IP6TABLES_RULES_FILE"

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
            log "INFO" "ip6tables found. Flushing rules to ensure IPv6 is open."
            ip6tables -D INPUT -j LABO_INPUT_V6 2>/dev/null || true
            ip6tables -D DOCKER-USER -j LABO_DOCKER_USER_V6 2>/dev/null || true
            ip6tables -F LABO_INPUT_V6 2>/dev/null || true
            ip6tables -F LABO_DOCKER_USER_V6 2>/dev/null || true
            ip6tables -X LABO_INPUT_V6 2>/dev/null || true
            ip6tables -X LABO_DOCKER_USER_V6 2>/dev/null || true
            ip6tables -P INPUT ACCEPT
            ip6tables -P FORWARD ACCEPT
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

apply_rules_nftables() {
    log "INFO" "Applying rules using nftables (native) backend..."

    # Clean up legacy iptables rules (if they exist) ---
    # This prevents conflicts if switching from iptables to nftables.
    # We must check if iptables exists before trying to use it.
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

    local nft_set_elements_v4
    nft_set_elements_v4=$(<"$IP_RANGE_FILE_V4" tr '\n' ',' | sed 's/,$//')
    if [[ -z "$nft_set_elements_v4" ]]; then
        log "WARN" "IPv4 range file is empty. Using dummy IP."
        nft_set_elements_v4="192.0.2.1"
    fi

    local nft_set_elements_v6=""
    if [[ "$GEOBLOCK_IPV6" == true && -s "$IP_RANGE_FILE_V6" ]]; then
        nft_set_elements_v6=$(<"$IP_RANGE_FILE_V6" tr '\n' ',' | sed 's/,$//')
    fi
    if [[ "$GEOBLOCK_IPV6" == true && -z "$nft_set_elements_v6" ]]; then
        log "WARN" "IPv6 range file is empty. Using dummy IP."
        nft_set_elements_v6="::ffff:192.0.2.1"
    fi

    log "INFO" "Generating atomic nftables ruleset..."
    log "INFO" "Flushing existing $NFT_TABLE_NAME table..."
    nft delete table inet $NFT_TABLE_NAME 2>/dev/null || true

    # We pipe the ruleset directly to 'nft -f -'
    cat <<-EOF | nft -f -
        table inet $NFT_TABLE_NAME {

            # ========= SETS =========

            set private_nets_v4 {
                type ipv4_addr
                flags interval
                elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }
            }

            set private_nets_v6 {
                type ipv6_addr
                flags interval
                elements = { fc00::/7, fe80::/10 }
            }

            set $ALLOW_LIST_NAME_V4 {
                type ipv4_addr
                flags interval
                elements = { $nft_set_elements_v4 }
            }

            set ssh_ratelimit {
                type ipv4_addr
                flags dynamic ; timeout 10s ; size 65536 ;
            }
            set ssh_blacklist {
                type ipv4_addr
                flags dynamic ; timeout 5m ; size 65536 ;
            }

            $(if [[ "$GEOBLOCK_IPV6" == true ]]; then
                echo "
                set $ALLOW_LIST_NAME_V6 {
                    type ipv6_addr
                    flags interval
                    elements = { $nft_set_elements_v6 }
                }
                "
            fi)

            # ========= CHAINS =========

            chain INPUT {
                type filter hook input priority -10; policy accept;
                iifname "lo" accept
                ct state related,established accept
                ct state invalid counter drop
                ip saddr @private_nets_v4 accept
                ip6 saddr @private_nets_v6 accept
                ip saddr @ssh_blacklist counter log prefix "INPUT SSH BL-DROP: " drop
                tcp dport $SSH_PORT ct state new \
                    add @ssh_ratelimit { ip saddr limit rate over 10/second } \
                    add @ssh_blacklist { ip saddr } \
                    counter log prefix "INPUT SSH RATE-DROP: " drop
                ip saddr != @$ALLOW_LIST_NAME_V4 counter log prefix "INPUT GEO-DROP: " drop

                $(if [[ "$GEOBLOCK_IPV6" == true ]]; then
                    echo "ip6 saddr != @$ALLOW_LIST_NAME_V6 counter log prefix \"INPUT6 GEO-DROP: \" drop"
                fi)
            }

            chain DOCKER_PRE {
                type filter hook forward priority -10; policy accept;
                ct state related,established accept
                ct state invalid counter drop
                ip saddr @private_nets_v4 accept
                ip6 saddr @private_nets_v6 accept
                ip saddr != @$ALLOW_LIST_NAME_V4 counter log prefix "DOCKER GEO-DROP: " drop

                $(if [[ "$GEOBLOCK_IPV6" == true ]]; then
                    echo "ip6 saddr != @$ALLOW_LIST_NAME_V6 counter log prefix \"DOCKER6 GEO-DROP: \" drop"
                fi)
            }
        }
EOF
    log "INFO" "nftables ruleset applied successfully."
}

###################
# Main Logic
###################
main() {
    # 1. Check root & setup traps
    check_root
    # 2. Parse -c, -b, -G, -s flags
    parse_arguments "$@"
    # 3. Check internet
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