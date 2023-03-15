#!/usr/bin/env bash

optimizeFs() {
    local fstab_f="/etc/fstab"
    echo -e "\n\nFilesystem optimizations for SSD/MicroSD"
    cp -a "$fstab_f" "$fstab_f.bak"
    echo "$fstab_f backed up to $fstab_f.bak"
    sed -i 's/defaults/defaults,noatime/g' "$fstab_f"
    echo "Filesystem optimizations done"
    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "$SCRIPT_D/utils.sh"
    checkSU || exit 1
    optimizeFs
    exit $?
fi
