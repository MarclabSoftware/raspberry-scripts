#!/usr/bin/env bash

###############################################################################
# SSH Security Audit Script
#
# This script automates the download, setup, and execution of ssh-audit tool
# to perform security assessments of SSH configurations. It includes error
# handling, cleanup procedures, and verification of required dependencies.
#
# Features:
# - Automatic download and extraction of latest ssh-audit
# - Security check to prevent root execution
# - Dependency verification (curl, unzip, python3)
# - Automatic cleanup of temporary files
# - Comprehensive error handling
#
# Usage:
#   ./ssh-audit.sh
#
# Note: This script must be run as a non-root user with sufficient permissions
# to execute Python scripts and access SSH configurations.
#
# Additional Options (commented out in script):
# - List all policies: ./ssh-audit.py -L
# - Use specific policy: ./ssh-audit.py -P "Policy Name" localhost
#
# Requirements:
# - curl
# - unzip
# - python3
# - Internet connection
#
# Author: LaboDJ
# Version: 1.0
# Last Updated: 2025/01/16
###############################################################################


# Enable strict mode for better error handling
# -e: exit on error
# -u: exit on undefined variable
# -o pipefail: exit on pipe failures
set -euo pipefail

# Define constants
readonly URL="https://github.com/jtesta/ssh-audit/archive/refs/heads/master.zip"
readonly FILENAME="ssh-audit-master.zip"
readonly FILEPATH_F="${HOME}/${FILENAME}"
readonly DIRPATH_D="${HOME}/${FILENAME%.zip}"

# Cleanup function to remove temporary files and directories
cleanup() {
    rm -f "${FILEPATH_F}"
    rm -rf "${DIRPATH_D}"
}

# Error handler function
# Parameters:
# $1: Line number where the error occurred
error_handler() {
    echo "Error at line $1" >&2
    cleanup
    exit 1
}

# Set up error trap to catch and handle errors
trap 'error_handler ${LINENO}' ERR

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "Please run this script as a normal user" >&2
    exit 1
fi

# Check if required commands are available in the system
for cmd in curl unzip python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found: $cmd" >&2
        exit 1
    fi
done

# Change to home directory safely
cd "${HOME}" || exit 1

# Clean up any residual files from previous runs
cleanup

# Download and extract ssh-audit
echo "Downloading ssh-audit..."
if ! curl -sSfL "${URL}" -o "${FILEPATH_F}"; then
    echo "Error during download" >&2
    cleanup
    exit 1
fi

echo "Extracting files..."
if ! unzip -q "${FILEPATH_F}"; then
    echo "Error during extraction" >&2
    cleanup
    exit 1
fi

# Remove the zip file after extraction
rm -f "${FILEPATH_F}"

# Verify that the Python script exists
if [ ! -f "${DIRPATH_D}/ssh-audit.py" ]; then
    echo "ssh-audit.py file not found" >&2
    cleanup
    exit 1
fi

# Run ssh-audit
echo "Running ssh-audit..."
"${DIRPATH_D}/ssh-audit.py" localhost -4

# Additional options available (commented out)
#"${DIRPATH_D}/ssh-audit.py" -L
#"${DIRPATH_D}/ssh-audit.py" -P "Hardened OpenSSH Server v9.7 (version 1)" localhost

exit 0
