#!/bin/bash
# -------------------------------------------------------------------------------------------
#
# BashRansomVirusProtector.sh - Optimized Version
# Original by Marco Marcoaldi @ Managed Server S.r.l.
# Optimized version includes performance improvements and better error handling by LaboDJ
#
# --------------------------------------------------------------------------------------------

# Enable strict mode for better error handling and debugging
# -e: exit on error
# -u: treat unset variables as errors
# -o pipefail: return the exit status of the last command in a pipe that failed
set -euo pipefail

###################
# Global Constants
###################

declare -r FN='delegated-ripencc-latest'
declare -r MD5FN='delegated-ripencc-latest.md5'
declare -r SITE="https://ftp.ripe.net/pub/stats/ripencc/"
declare -r REQUIRED_COMMANDS=(curl md5sum awk)

###################
# Global Variables
###################

declare -A CIDR_CACHE
declare verbose=0
declare headerfilename=""
declare prefix=""
declare postfix=""
declare countrieslist=""

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
    exit 1
}

# Function to calculate CIDR
calculate_cidr() {
    local num_hosts=$1

    if [ "$num_hosts" -le 1 ]; then
        echo 32
    elif [ "$num_hosts" -le 2 ]; then
        echo 31
    elif [ "$num_hosts" -le 4 ]; then
        echo 30
    elif [ "$num_hosts" -le 8 ]; then
        echo 29
    elif [ "$num_hosts" -le 16 ]; then
        echo 28
    elif [ "$num_hosts" -le 32 ]; then
        echo 27
    elif [ "$num_hosts" -le 64 ]; then
        echo 26
    elif [ "$num_hosts" -le 128 ]; then
        echo 25
    elif [ "$num_hosts" -le 256 ]; then
        echo 24
    elif [ "$num_hosts" -le 512 ]; then
        echo 23
    elif [ "$num_hosts" -le 1024 ]; then
        echo 22
    elif [ "$num_hosts" -le 2048 ]; then
        echo 21
    elif [ "$num_hosts" -le 4096 ]; then
        echo 20
    elif [ "$num_hosts" -le 8192 ]; then
        echo 19
    elif [ "$num_hosts" -le 16384 ]; then
        echo 18
    elif [ "$num_hosts" -le 32768 ]; then
        echo 17
    elif [ "$num_hosts" -le 65536 ]; then
        echo 16
    elif [ "$num_hosts" -le 131072 ]; then
        echo 15
    elif [ "$num_hosts" -le 262144 ]; then
        echo 14
    elif [ "$num_hosts" -le 524288 ]; then
        echo 13
    elif [ "$num_hosts" -le 1048576 ]; then
        echo 12
    elif [ "$num_hosts" -le 2097152 ]; then
        echo 11
    elif [ "$num_hosts" -le 4194304 ]; then
        echo 10
    elif [ "$num_hosts" -le 8388608 ]; then
        echo 9
    elif [ "$num_hosts" -le 16777216 ]; then
        echo 8
    elif [ "$num_hosts" -le 33554432 ]; then
        echo 7
    elif [ "$num_hosts" -le 67108864 ]; then
        echo 6
    elif [ "$num_hosts" -le 134217728 ]; then
        echo 5
    elif [ "$num_hosts" -le 268435456 ]; then
        echo 4
    elif [ "$num_hosts" -le 536870912 ]; then
        echo 3
    elif [ "$num_hosts" -le 1073741824 ]; then
        echo 2
    else
        echo 1
    fi
}

# Verify required commands are installed
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
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        esac
    done

    if [[ -z "$countrieslist" ]]; then
        echo "No countries specified. Please provide country codes." >&2
        exit 1
    fi
}

download_with_retry() {
    local url="$1"
    local output="$2"
    local retries=3
    local timeout=10

    while ((retries > 0)); do
        if curl -s --connect-timeout "$timeout" "$url" -o "$output"; then
            return 0
        fi
        ((retries--))
        sleep 1
    done

    echo "Failed to download $output from $url after 3 attempts" >&2
    return 1
}

verify_md5() {
    local file="$1"
    local md5file="$2"

    local original_md5
    original_md5=$(awk '/MD5/ {print $NF}' "$md5file")

    [[ -z "$original_md5" ]] && {
        echo "MD5 not found in $md5file" >&2
        return 1
    }

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
    local -A country_set=() # Initialize empty associative array
    local IFS=','
    local codes
    read -ra codes <<<"$countrieslist"

    for code in "${codes[@]}"; do
        country_set["$code"]=1
    done

    # Pre-allocate results array for better performance
    local -a results=()

    while IFS='|' read -r _ country recordtype ip value _; do
        [[ "$recordtype" == "ipv4" && -n "${country_set[$country]:-}" ]] || continue

        if [[ -z "${CIDR_CACHE[$value]:-}" ]]; then
            CIDR_CACHE[$value]=$(calculate_cidr "$value")
        fi

        results+=("${prefix}${ip}/${CIDR_CACHE[$value]}${postfix}")

        # Flush results when array gets too large
        if ((${#results[@]} >= 1000)); then
            printf '%s\n' "${results[@]}"
            results=()
        fi
    done <"$FN"

    # Print remaining results
    [[ ${#results[@]} -gt 0 ]] && printf '%s\n' "${results[@]}"
}

process_addresses_parallel() {
    local cpus
    cpus=$(nproc)
    local total_lines
    total_lines=$(wc -l <"$FN")
    local chunk=$((total_lines / cpus))

    # Create temporary directory for parallel processing
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "${tmpdir:-/tmp/temp$$}"' EXIT

    # Split file into chunks based on complete records
    local start_line=1
    for ((i = 0; i < cpus; i++)); do
        local end_line=$((start_line + chunk - 1))
        if ((i == cpus - 1)); then
            # Last chunk gets remaining lines
            end_line=$total_lines
        fi

        {
            sed -n "${start_line},${end_line}p" "$FN" |
                awk -v prefix="$prefix" -v postfix="$postfix" -v countries="$countrieslist" '
            BEGIN {
                split(countries, country_array, ",")
                for (i in country_array) {
                    valid_countries[country_array[i]] = 1
                }
            }

            function calculate_cidr(hosts) {
                return 32 - log(hosts)/log(2)
            }

            BEGIN { FS = "|" }

            $3 == "ipv4" && ($2 in valid_countries) {
                printf "%s%s/%d%s\n", prefix, $4, calculate_cidr($5), postfix
            }' >"$tmpdir/part$i"
        } &

        start_line=$((end_line + 1))
    done
    wait

    # Combine and sort unique results
    sort -u "$tmpdir"/part*
}

main() {
    check_installed_commands
    parse_arguments "$@"

    download_with_retry "${SITE}${FN}" "$FN"
    download_with_retry "${SITE}${MD5FN}" "$MD5FN"

    verify_md5 "$FN" "$MD5FN"

    [[ -n "$headerfilename" ]] && cat "$headerfilename"

    if command -v nproc >/dev/null 2>&1 && (($(nproc) > 1)); then
        process_addresses_parallel
    else
        process_addresses
    fi
}

# Execute main function
main "$@"