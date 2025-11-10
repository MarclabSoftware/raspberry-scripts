#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------
#
# BashRansomVirusProtector.sh - Enhanced Version
# Original by Marco Marcoaldi @ Managed Server S.r.l.
# Enhanced version with performance optimizations and security improvements by LaboDJ
#
# Last Updated: 2025/01/22
#
# --------------------------------------------------------------------------------------------

# Enable strict mode and error handling (https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/)
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C
export LANG=C

###################
# Global Constants
###################

readonly FN='delegated-ripencc-latest'
readonly MD5FN="$FN.md5"
readonly SITE="https://ftp.ripe.net/pub/stats/ripencc/"
readonly REQUIRED_COMMANDS=(curl md5sum awk nproc sort sed)
TEMP_DIR=$(mktemp -d)
readonly TEMP_DIR
readonly LOCK_FILE="/tmp/${0##*/}.lock"
readonly MAX_RETRIES=3
readonly TIMEOUT=10

###################
# Global Variables
###################

declare -i verbose=0
declare headerfilename=""
declare prefix=""
declare postfix=""
declare countrieslist=""

###################
# Cleanup Function
###################

cleanup() {
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
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

handle_error() {
    local exit_code=$?
    local line_number=$1
    log "ERROR" "Script failed at line $line_number with exit code $exit_code"
    exit "$exit_code"
}

# Fatal error handler
# Usage: die "Error message"
die() {
    log "ERROR" "$*"
    exit 1
}

# Handle SIGINT (Ctrl+C)
trap 'log "INFO" "Received SIGINT"; exit 130' INT
# Handle SIGTERM
trap 'log "INFO" "Received SIGTERM"; exit 143' TERM
# Handle ERR
trap 'handle_error $LINENO' ERR
# Handle EXIT
trap 'cleanup' EXIT

###################
# Utility Functions
###################

check_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        if kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
            die "Another instance is running"
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ >"$LOCK_FILE"
}

check_installed_commands() {
    local missing_commands=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd")
    done
    [[ ${#missing_commands[@]} -eq 0 ]] || die "Missing commands: ${missing_commands[*]}"
}

show_usage() {
    cat <<EOF
Usage: $0 [options]
Options:
  -H, --header       Header file name to prepend to output
  -p, --prefix       Prefix for each line of output
  -c, --countries    Country codes, comma-separated (e.g., 'RU,IT')
  -P, --postfix      Postfix for each line of output
  -v, --verbose      Enable verbose output
EOF
    exit 1
}

parse_arguments() {
    [[ $# -eq 0 ]] && show_usage

    while [[ $# -gt 0 ]]; do
        case $1 in
        -H | --header)
            headerfilename="$2"
            shift 2
            ;;
        -p | --prefix)
            prefix="$2"
            shift 2
            ;;
        -c | --countries)
            countrieslist="$2"
            shift 2
            ;;
        -P | --postfix)
            postfix="$2"
            shift 2
            ;;
        -v | --verbose)
            verbose=1
            shift
            ;;
        *) die "Unknown option: $1" ;;
        esac
    done

    if [[ -z "$countrieslist" ]]; then
        echo "No countries specified. Please provide country codes." >&2
        exit 1
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    local attempt=1

    while ((attempt <= MAX_RETRIES)); do
        if curl -sfS --connect-timeout "$TIMEOUT" --retry 3 --retry-delay 2 "$url" -o "$output"; then
            ((verbose)) && log "INFO" "Downloaded $output successfully"
            return 0
        fi
        ((attempt++))
        sleep $((attempt * 2))
    done
    die "Failed to download $output after $MAX_RETRIES attempts"
}

verify_md5() {
    local file="$1"
    local md5file="$2"

    local original_md5
    original_md5=$(awk '/MD5/ {print $NF}' "$md5file") || die "Failed to read MD5"
    [[ -z "$original_md5" ]] && die "MD5 not found in $md5file"

    local computed_md5
    computed_md5=$(md5sum "$file" | cut -d' ' -f1)

    if [[ "$original_md5" == "$computed_md5" ]]; then
        ((verbose)) && echo "MD5 verification successful"
        return 0
    else
        echo "MD5 verification failed" >&2
        return 1
    fi
}

process_addresses() {
    local cpus
    cpus=$(nproc)
    local buffer_size
    buffer_size="$(free -m | awk '/Mem:/ {print int($2/4)}')M"
    local total_lines
    total_lines=$(wc -l <"$TEMP_DIR/$FN")
    local chunk=$((total_lines / cpus + 1))

    # Prepare AWK script for better performance
    cat >"$TEMP_DIR/process.awk" <<'EOF'
BEGIN {
    FS = "|"
    split(ENVIRON["countries"], country_array, ",")
    for (i in country_array) valid_countries[country_array[i]] = 1
}

function calculate_cidr(hosts) {
    return 32 - log(hosts)/log(2)
}

$3 == "ipv4" && ($2 in valid_countries) {
    printf "%s%s/%d%s\n", ENVIRON["prefix"], $4, calculate_cidr($5), ENVIRON["postfix"]
}
EOF

    # Export variables for AWK
    export prefix postfix countries="$countrieslist"

    # Parallel processing with improved memory management
    for ((i = 0; i < cpus; i++)); do
        {
            sed -n "$((i * chunk + 1)),$((i == cpus - 1 ? total_lines : (i + 1) * chunk))p" "$TEMP_DIR/$FN" |
                awk -f "$TEMP_DIR/process.awk"
        } >"$TEMP_DIR/part$i" &
    done
    wait

    # Efficient sorting and uniquing
    sort -S "$buffer_size" -T "$TEMP_DIR" -u --parallel="$cpus" "$TEMP_DIR"/part* || die "Sort failed"
}

main() {
    check_lock
    check_installed_commands
    parse_arguments "$@"

    download_file "${SITE}${FN}" "$TEMP_DIR/$FN"
    download_file "${SITE}${MD5FN}" "$TEMP_DIR/$MD5FN"
    verify_md5 "$TEMP_DIR/$FN" "$TEMP_DIR/$MD5FN"

    [[ -n "$headerfilename" && -f "$headerfilename" ]] && cat "$headerfilename"
    process_addresses
}

main "$@"
