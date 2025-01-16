#!/bin/bash

# Enable strict mode for better error handling and debugging
# -e: exit on error
# -u: treat unset variables as errors
# -o pipefail: return the exit status of the last command in a pipe that failed
set -euo pipefail

###################
# Global Constants
###################

# Default country code if none specified
declare -r DEFAULT_COUNTRIES="IT"

# Get the directory where the script is located
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
readonly SCRIPT_DIR

# Directory structure for IP lists
declare -r IP_LIST_DIR="$SCRIPT_DIR/lists"
declare -r ALLOW_LIST_DIR="$IP_LIST_DIR/allow"
declare -r ALLOW_LIST_NAME="allowlist"
declare -r BLOCK_LIST_DIR="$IP_LIST_DIR/block"
declare -r BLOCK_LIST_URL="https://raw.githubusercontent.com/Adamm00/IPSet_ASUS/master/filter.list"
declare -r BLOCK_LIST_FILE_NAME="$IP_LIST_DIR/blocklists.txt"

# Temporary files
declare -r IPSET_FILE="/tmp/$ALLOW_LIST_NAME.ipset.txt"
declare -r IP_RANGE_FILE="/tmp/$ALLOW_LIST_NAME.iprange.txt"

# File descriptors for I/O optimization
declare -r FD_IPSET=3
declare -r FD_IPRANGE=4

# Configuration constants
declare -r MAX_RETRIES=10
declare -r REQUIRED_COMMANDS=(curl ipset iptables iprange ping)
declare -r CONNECTIVITY_CHECK_SITES=(github.com google.com)

###################
# Global Variables
###################

declare ALLOWED_COUNTRIES="$DEFAULT_COUNTRIES"
declare USE_BLOCKLIST=false
declare DISABLE_IPV6=false
declare SSH_PORT=22
declare CLEANUP_REGISTERED=false

###################
# Error Handling
###################

# Enhanced error handling function
handle_error() {
    local exit_code=$?
    local line_number=$1
    log "ERROR" "Script failed at line $line_number with exit code $exit_code"
    cleanup
    exit $exit_code
}

# Setup enhanced signal handlers
setup_signal_handlers() {
    # Handle SIGINT (Ctrl+C)
    trap 'log "INFO" "Received SIGINT, cleaning up..."; cleanup; exit 130' INT

    # Handle SIGTERM
    trap 'log "INFO" "Received SIGTERM, cleaning up..."; cleanup; exit 143' TERM

    # Handle ERR
    trap 'handle_error $LINENO' ERR

    # Handle EXIT
    trap 'cleanup' EXIT

    CLEANUP_REGISTERED=true
}

###################
# Logging Functions
###################

# Enhanced logging function with timestamp and PID
# Usage: log "INFO" "Message"
log() {
    local level="$1"
    shift
    local timestamp
    local pid
    local format='%Y-%m-%d %H:%M:%S.%N'

    timestamp=$(date +"$format" | cut -b1-23) || return 1
    pid=$$

    printf '[%s] [%s] [PID:%d] %s\n' "$timestamp" "$level" "$pid" "$*" >&2
}

# Fatal error handler
# Usage: die "Error message"
die() {
    log "ERROR" "$*"
    cleanup
    exit 1
}

###################
# Cleanup Functions
###################

# Cleanup temporary files
cleanup() {
    if [[ "$CLEANUP_REGISTERED" == true ]]; then
        log "INFO" "Performing cleanup..."
        # Close file descriptors if they're open
        if [[ -e /proc/$$/fd/$FD_IPSET ]]; then
            eval "exec $FD_IPSET>&-"
        fi
        if [[ -e /proc/$$/fd/$FD_IPRANGE ]]; then
            eval "exec $FD_IPRANGE>&-"
        fi
        # Remove temporary files
        rm -f "$IPSET_FILE" "$IP_RANGE_FILE"
    fi
}

check_root() {
    [[ "${EUID:-$(id -u)}" -ne 0 ]] && die "Please run as root/sudo"
    setup_signal_handlers
}

###################
# I/O Functions
###################

setup_file_descriptors() {
    # Open file descriptors for writing
    eval "exec $FD_IPSET>\"$IPSET_FILE\""
    eval "exec $FD_IPRANGE>\"$IP_RANGE_FILE\""
}

write_to_ipset_file() {
    echo "$1" >&$FD_IPSET
}

write_to_iprange_file() {
    echo "$1" >&$FD_IPRANGE
}

###################
# Argument Parsing
###################

# Display usage information
print_usage() {
    cat <<EOF

Usage: $0 [-c countries] [-b] [-6] [-s sshPort] [-h]

Options:
    -c countries   Specify allowed countries (comma-separated, e.g., IT,DE,FR)
    -b             Enable block lists
    -6             Disable IPv6
    -s sshPort     Specify SSH port (default: 22)
    -h             Display this help message
EOF
    exit 1
}

# Parse command line arguments
parse_arguments() {
    [[ $# -eq 0 ]] && print_usage

    OPTIND=1
    local OPTERR=1

    while getopts ":c:b6s:h" opt; do
        case $opt in
        c) ALLOWED_COUNTRIES="$OPTARG" ;;
        b) USE_BLOCKLIST=true ;;
        6) DISABLE_IPV6=true ;;
        s) SSH_PORT="$OPTARG" ;;
        h) print_usage ;;
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

    # Validate SSH port
    if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        die "SSH port must be a number between 1 and 65535"
    fi

    # Validate country codes
    if [[ ! "$ALLOWED_COUNTRIES" =~ ^[A-Z,]+$ ]]; then
        die "Country codes must be uppercase and comma-separated (e.g., IT,FR,DE)"
    fi
}

###################
# Network Functions
###################

# Check internet connectivity before proceeding
check_connectivity() {
    local success=false
    log "INFO" "Checking connectivity..."

    while ! $success; do
        for site in "${CONNECTIVITY_CHECK_SITES[@]}"; do
            if ping -c 1 -W 5 "$site" &>/dev/null; then
                success=true
                log "INFO" "Connectivity check passed with $site"
                return 0
            fi
        done
        $success || {
            log "WARN" "Connectivity check failed. Retrying in 5 seconds..."
            sleep 5
        }
    done
}

# Verify required commands are installed
check_installed_commands() {
    local missing_commands=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd")
    done
    [[ ${#missing_commands[@]} -eq 0 ]] || die "Missing commands: ${missing_commands[*]}"
}

###################
# Firewall Functions
###################

# Reset iptables chains
flush_iptables() {
    iptables -F INPUT || die "Failed to flush INPUT chain."
    iptables -F DOCKER-USER || die "Failed to flush DOCKER-USER chain."
}

# Create logging chain for dropped packets
create_log_chain() {
    local chain_name="$1"
    local log_prefix="$2"
    iptables -N "$chain_name" 2>/dev/null || iptables -F "$chain_name"
    iptables -A "$chain_name" -j LOG --log-level 4 --log-prefix "$log_prefix"
    iptables -A "$chain_name" -j DROP
}

# Optimize ipset creation
fast_ipset() {
    local file="$1"
    local list_name="$2"
    [[ -f "$file" ]] || return 1
    while IFS= read -r line; do
        write_to_ipset_file "add $list_name $line"
    done <"$file"
}

# Disable IPv6 if requested
disable_ipv6() {
    local rules=(-P INPUT DROP -P OUTPUT DROP -P FORWARD DROP)
    ip6tables "${rules[@]}"
}

# Retry command with exponential backoff
retry_command() {
    local retries=0
    local command=("$@")

    while ((retries < MAX_RETRIES)); do
        "${command[@]}" && return 0
        ((retries++))
        log "WARN" "Command failed: ${command[*]}. Retry $retries/$MAX_RETRIES"
        sleep $((2 ** retries)) # Exponential backoff
    done
    die "Command failed after $MAX_RETRIES retries: ${command[*]}"
}

###################
# Main Logic
###################

# Download and process blocklists
download_blocklists() {
    retry_command curl -sSL "$BLOCK_LIST_URL" -o "$BLOCK_LIST_FILE_NAME" ||
        die "Failed to download block list"

    cd "$BLOCK_LIST_DIR" || die "Failed to change directory to $BLOCK_LIST_DIR"
    rm -f ./*

    local urls
    mapfile -t urls <"$BLOCK_LIST_FILE_NAME"

    # Parallel download with job limit
    local max_jobs=8
    for url in "${urls[@]}"; do
        [[ -z "$url" || "${url:0:1}" == "#" ]] && continue
        while (($(jobs -p | wc -l) >= max_jobs)); do
            wait -n
        done
        (
            log "INFO" "Downloading: $url"
            retry_command curl -sSL -OJ "$url" || die "Failed to download $url"
        ) &
    done
    wait
}

# Setup iptables rules
setup_iptables_rules() {
    local base_rules=(
        "-A INPUT -m state --state INVALID -j DROP"
        "-A INPUT -p tcp --dport $SSH_PORT -m state --state NEW -m recent --set"
        "-A INPUT -p tcp --dport $SSH_PORT -m state --state NEW -m recent --update --seconds 10 --hitcount 10 -j DROP"
        "-A INPUT -i lo -j ACCEPT"
        "-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT"
        "-A INPUT -m set ! --match-set $ALLOW_LIST_NAME src -j LOG_AND_DROP_INPUT"
    )

    local docker_rules=(
        "-I DOCKER-USER -m set ! --match-set $ALLOW_LIST_NAME src -j LOG_AND_DROP_DOCKER"
        "-I DOCKER-USER -m state --state RELATED,ESTABLISHED -j RETURN"
        "-I DOCKER-USER -m state --state INVALID -j DROP"
        "-I DOCKER-USER -i lo -j RETURN"
    )

    {
        echo "*filter"
        printf '%s\n' "${base_rules[@]}" "${docker_rules[@]}"
        echo "COMMIT"
    } | iptables-restore --noflush
}

# Main execution function
main() {
    check_root
    setup_file_descriptors
    check_installed_commands
    parse_arguments "$@"
    check_connectivity

    mkdir -p "$ALLOW_LIST_DIR" "$BLOCK_LIST_DIR" || die "Failed to create directories"

    $USE_BLOCKLIST && download_blocklists

    cd "$IP_LIST_DIR" || die "Failed to change directory"

    retry_command ./bashransomvirusprotector.sh -c "$ALLOWED_COUNTRIES" >"$ALLOW_LIST_DIR/countries.txt"

    if [[ -z "$(ls -A "$BLOCK_LIST_DIR")" ]]; then
        iprange --optimize "$ALLOW_LIST_DIR"/* >&$FD_IPRANGE
    else
        iprange --optimize "$ALLOW_LIST_DIR"/* --except "$BLOCK_LIST_DIR"/* >&$FD_IPRANGE
    fi

    [[ -s "$IP_RANGE_FILE" ]] || die "IP range file not found or empty"

    create_log_chain "LOG_AND_DROP_INPUT" "INPUT DROP: "
    create_log_chain "LOG_AND_DROP_DOCKER" "DOCKER DROP: "

    flush_iptables

    # Manage ipset
    if ipset -n -q list "$ALLOW_LIST_NAME" >/dev/null; then
        ipset flush "$ALLOW_LIST_NAME"
    else
        ipset create "$ALLOW_LIST_NAME" hash:net || die "Failed to create ipset $ALLOW_LIST_NAME"
    fi

    ipset -o save save "$ALLOW_LIST_NAME" >&$FD_IPSET
    fast_ipset "$IP_RANGE_FILE" "$ALLOW_LIST_NAME"
    ipset destroy "$ALLOW_LIST_NAME" || die "Failed to destroy $ALLOW_LIST_NAME ipset"
    ipset restore <"$IPSET_FILE"

    $DISABLE_IPV6 && disable_ipv6
    setup_iptables_rules

    log "INFO" "Configuration completed successfully"
}

main "$@"
