#!/usr/bin/env bash

###############################################################################
# Universal System Clone Script (RPi & x86) v2.2
#
# Creates a bootable 1:1 clone of the running Linux system to an external drive.
# Automatically adapts to the source architecture (MBR/Legacy or GPT/UEFI).
#
# Key Features:
# - Auto-Detection: Identifies source disk and partition table type automatically.
# - Boot Safety: Generates fresh UUIDs and patches /etc/fstab, cmdline, and loaders.
# - Optimization: SSD-friendly formatting and smart rsync exclusions (caches, tmp).
# - Robustness: Strict error handling, safe cleanup traps, and LVM/LUKS guards.
#
# Usage: sudo ./clone_disk.sh
#
# Requirements: rsync, parted, mkfs.*, blkid, lsblk, findmnt
# Author: LaboDJ | Last Updated: 2026/03/20
###############################################################################

# Enable strict mode:
# -E: Inherit traps (ERR, DEBUG, RETURN) in functions.
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error.
# -o pipefail: The return value of a pipeline is the status of the last
#              command to exit with a non-zero status, or zero if all exit ok.
set -Eeuo pipefail

###################
# Configuration
###################

# Modern ext4 options for performance and reliability on SSDs (512GB+)
# - 64bit: Allows filesystems > 16TB (future proofing).
# - huge_file: Allows files > 2TB.
# - metadata_csum: Checksums for metadata integrity.
# - lazy_itable_init=0: Initialize inode tables immediately (avoids background activity).
declare -r -a EXT4_OPTIONS=(
    "-O" "64bit,has_journal,extent,huge_file,flex_bg,metadata_csum,dir_nlink,extra_isize,fast_commit"
    "-E" "lazy_itable_init=0,lazy_journal_init=0"
    "-m" "1"
)

# Inode ratio: One inode per 16KB.
# This is a good balance for system drives which have many small files.
declare -r INODE_RATIO="16384"

# Required commands for dependency checks
declare -ra REQUIRED_COMMANDS=(rsync parted mkfs.vfat mkfs.ext4 blkid lsblk grep awk sed dd stat truncate udevadm partprobe findmnt mountpoint fstrim wipefs)

# Known boot mount points to validate against fstab (order = priority)
declare -ra BOOT_MOUNT_CANDIDATES=(/boot/firmware /boot/efi /efi /boot)

# Excludes for rsync
# These paths are excluded to keep the backup clean and avoid copying runtime states.
declare -ra EXCLUDES=(
    "/dev/*" "/proc/*" "/sys/*" "/tmp/*" "/run/*" "/mnt/*" "/media/*" "/lost+found"
    "/var/cache/apt/archives/*" "/var/log/*" "/var/tmp/*"
    "/var/lib/pacman/sync/*"
    "/var/cache/pacman/pkg/*"
    "/root/.cache/*"
    "/home/*/.cache/*"
    "*.swp" "*.log" "*.tmp"
    "/swapfile" "/swap"
    "/boot/firmware" "/boot/efi" # Exclude mount points completely to avoid permission errors on FAT32 (Error 23)
    "/var/lib/docker/*" "/var/lib/containerd/*" # Exclude container state (prevents rsync errors on live systems)
)

# Colors
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r RED='\033[0;31m'
declare -r NC='\033[0m' # No Color

# Global Variables
declare DST_MOUNT_ROOT=""
declare SRC_DEVICE=""
declare DST_DEVICE=""
declare SRC_TABLE_TYPE=""
declare DST_PART1=""
declare DST_PART2=""
declare BOOT_MOUNT=""
declare -a MOUNTED_BY_SCRIPT=()

###################
# Helper Functions
###################

# Logging helper with timestamp and color
log() {
    local level=$1
    shift
    local color=$NC
    case "$level" in
        INFO) color=$GREEN ;;
        WARN) color=$YELLOW ;;
        ERROR) color=$RED ;;
    esac
    printf '%(%Y-%m-%d %H:%M:%S)T %b[%s]%b %s\n' -1 "$color" "$level" "$NC" "$*" >&2
}

# Verify script is run as root
check_root() {
    if [[ "$(id -u)" != "0" ]]; then
        log "ERROR" "This script must be run as root!"
        exit 1
    fi
}

# Check for all required dependencies
check_dependencies() {
    local missing=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    [[ ${#missing[@]} -eq 0 ]] || { log "ERROR" "Missing required commands: ${missing[*]}"; exit 1; }
}

# Detect partition table type of a disk (mbr or gpt)
# Args: $1 - disk device (e.g., /dev/sda)
# Returns: "gpt", "mbr", or "unknown"
detect_partition_table() {
    local disk=$1
    local label
    # Use parted to query the label type safely
    # We use || true to prevent pipefail from exiting if grep finds nothing
    # LC_ALL=C forces English output so grep "Partition Table" works on all locales
    label=$(LC_ALL=C parted -s "$disk" print 2>/dev/null | grep "Partition Table" | awk '{print $3}' || true)
    if [[ "$label" == "gpt" ]]; then
        echo "gpt"
    elif [[ "$label" == "msdos" ]]; then
        echo "mbr"
    else
        echo "unknown"
    fi
}

# Get partition device name handling nvme/mmcblk naming conventions
# Args: $1 - disk device, $2 - partition number
# Returns: Partition path (e.g., /dev/nvme0n1p1 or /dev/sda1)
get_partition_device() {
    local disk=$1
    local part_num=$2
    # NVMe and MMC drives use 'p' separator (e.g., mmcblk0p1)
    if [[ "$disk" =~ nvme ]] || [[ "$disk" =~ mmcblk ]]; then
        echo "${disk}p${part_num}"
    else
        echo "${disk}${part_num}"
    fi
}

# Get UUID of a partition
# Args: $1 - partition device
get_uuid() {
    blkid -s UUID -o value "$1"
}

# Get PARTUUID of a partition
# Args: $1 - partition device
get_partuuid() {
    blkid -s PARTUUID -o value "$1"
}

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

# Detect the active boot mount point on the running system.
# Checks known candidates in priority order; falls back to /boot.
# Returns: The boot mount path (e.g., /boot/firmware, /boot/efi, /boot)
detect_boot_mount() {
    for candidate in "${BOOT_MOUNT_CANDIDATES[@]}"; do
        if mountpoint -q "$candidate"; then
            echo "$candidate"
            return
        fi
    done
    # Fallback to /boot (standard for Arch XBOOTLDR or straight ESP)
    echo "/boot"
}

# Patch systemd-boot loader entries in a directory.
# Replaces root= parameters with the new PARTUUID.
# @param $1 - loader entries directory path
# @param $2 - new root PARTUUID value
_patch_loader_entries() {
    local entries_dir="$1"
    local new_partuuid="$2"

    [[ -d "$entries_dir" ]] || return 1

    log "INFO" "Patching systemd-boot entries in $entries_dir..."
    shopt -s nullglob
    trap 'shopt -u nullglob' RETURN
    local patched=false
    for entry in "$entries_dir"/*.conf; do
        patched=true
        log "INFO" "Patching systemd-boot entry: $entry"
        if grep -q "root=" "$entry"; then
            sed -E -i "s/root=[^ ]+/root=PARTUUID=$new_partuuid/g" "$entry"
        fi
    done
    [[ "$patched" == true ]]
}

# Verify systemd-boot loader entries contain the expected UUID/PARTUUID.
# @param $1 - loader entries directory path
# @param $2 - root UUID
# @param $3 - root PARTUUID
# @param $4 - label for logging (e.g., "" or "(fallback)")
# Returns: 0 if entries found, 1 if directory missing/empty
_verify_loader_entries() {
    local entries_dir="$1"
    local uuid="$2"
    local partuuid="$3"
    local label="${4:+ $4}"

    [[ -d "$entries_dir" ]] || return 1

    local found=false
    shopt -s nullglob
    trap 'shopt -u nullglob' RETURN
    for entry in "$entries_dir"/*.conf; do
        found=true
        if grep -v "^[[:space:]]*#" "$entry" | grep -qF -e "$partuuid" -e "$uuid"; then
            log "INFO" "[PASS] systemd-boot entry${label} $(basename "$entry") updated"
        else
            log "ERROR" "[FAIL] systemd-boot entry${label} $(basename "$entry") NOT updated!"
        fi
    done
    [[ "$found" == true ]]
}

# Check if destination has enough space for the backup
# Args: $1 - source root partition, $2 - source boot partition, $3 - destination disk
check_space() {
    local src_root=$1
    local src_boot=$2
    local dst_disk=$3
    
    log "INFO" "Checking space requirements..."
    
    # Get used space in bytes
    local src_root_used
    src_root_used=$(df -B1 --output=used "$src_root" | tail -n 1)
    
    # For boot, it might be mounted or not. If mounted, use df.
    # If not mounted (unlikely for active system), we'd need mount.
    # Assuming active system where /boot/firmware or /boot is mounted.
    local src_boot_used
    src_boot_used=$(df -B1 --output=used "$src_boot" | tail -n 1)
    
    local total_src_used=$((src_root_used + src_boot_used))
    
    # Get destination size in bytes
    local dst_size
    dst_size=$(lsblk -b -n -o SIZE -d "$dst_disk")
    
    # Add Safety Margin: 2GB + 5% of source data
    # This accounts for filesystem overhead (inodes, journal) which grows with disk size/file count
    local base_margin=$((2 * 1024 * 1024 * 1024))
    local percent_margin=$((total_src_used * 5 / 100))
    local required_size=$((total_src_used + base_margin + percent_margin))
    
    if [[ "$dst_size" -lt "$required_size" ]]; then
        log "ERROR" "Destination disk is too small!"
        log "ERROR" "Source Data (Used + Margin): $(numfmt --to=iec-i --suffix=B "$required_size")"
        log "ERROR" "Destination Size:          $(numfmt --to=iec-i --suffix=B "$dst_size")"
        exit 1
    else
        log "INFO" "Space check passed."
        log "INFO" "Source Data: $(numfmt --to=iec-i --suffix=B "$total_src_used")"
        log "INFO" "Dest Size:   $(numfmt --to=iec-i --suffix=B "$dst_size")"
    fi
}

# Safely unmount a path, retrying with lazy unmount if busy
# Args: $1 - mount point
# shellcheck disable=SC2329
safe_unmount() {
    local mount_point="$1"
    if mountpoint -q "$mount_point"; then
        sync # Ensure data is flushed before unmounting
        umount "$mount_point" || {
            log "WARN" "Failed to unmount $mount_point, retrying with lazy unmount..."
            umount -l "$mount_point"
        }
    fi
}

# Cleanup function called on exit
# Ensures temporary mount points are unmounted and removed
# shellcheck disable=SC2329
cleanup() {
    if [[ -n "$DST_MOUNT_ROOT" ]]; then
        log "INFO" "Cleaning up..."
        # Optimize SSD before unmounting (only if DST_PART2 was set)
        if [[ -d "$DST_MOUNT_ROOT" ]] && [[ -n "$DST_PART2" ]]; then
            # Check if device supports discard (TRIM) to avoid errors/hangs
            local discard_max
            discard_max=$(lsblk -n -o DISC-MAX "$DST_PART2" 2>/dev/null || echo "0B")
            # Trim whitespace using read (avoids subshell + xargs fork)
            read -r discard_max <<< "$discard_max"

            if [[ "$discard_max" != "0B" ]] && [[ "$discard_max" != "0" ]]; then
                log "INFO" "Running fstrim on destination..."
                fstrim -v "$DST_MOUNT_ROOT" || true
            else
                log "INFO" "Skipping fstrim (not supported by device)."
            fi
        fi

        # Unmount in reverse order (LIFO) using the tracked array
        # This avoids hardcoded paths and "not mounted" warnings
        for (( idx=${#MOUNTED_BY_SCRIPT[@]}-1 ; idx>=0 ; idx-- )) ; do
            safe_unmount "${MOUNTED_BY_SCRIPT[idx]}"
        done

        rm -rf "$DST_MOUNT_ROOT"
    fi
}
trap cleanup EXIT
trap 'handle_error $LINENO' ERR

###################
# Core Logic
###################

# Interactive disk selection menu
select_disks() {
    echo "=== Disk Selection ==="
    echo "Available disks:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -E "sd|nvme|mmcblk" || true

    # Auto-detect Source Disk (The one hosting /)
    # We MUST clone the disk we are running from, because rsync copies from /
    log "INFO" "Auto-detecting source disk..."
    local root_part
    root_part=$(findmnt -n -o SOURCE /)
    
    # Handle potential mapper/root devices if simple resolution fails
    # Get the parent disk device (pkname gives the parent kernel name)
    local src_name
    src_name=$(lsblk -no pkname "$root_part" | head -n 1)
    
    SRC_DEVICE="/dev/$src_name"
    
    # Check for LVM/LUKS (Device Mapper)
    # Cloning LVM/LUKS requires complex volume recreation which is out of scope for this script.
    if [[ "$root_part" == *"/dev/mapper/"* ]] || [[ "$src_name" == dm-* ]]; then
        log "ERROR" "Detected LVM or LUKS encrypted root partition ($root_part)."
        log "ERROR" "This script does not currently support cloning LVM/LUKS systems."
        exit 1
    fi

    if [[ ! -b "$SRC_DEVICE" ]]; then
        log "ERROR" "Could not detect valid source device for root partition $root_part"
        exit 1
    fi
    
    log "INFO" "Detected Source: $SRC_DEVICE (hosts /)"

    # Safety Check: Verify Boot Mounts
    # If fstab defines a boot partition, it MUST be mounted, otherwise rsync will copy to the wrong place
    log "INFO" "Verifying boot mount points..."
    for bm in "${BOOT_MOUNT_CANDIDATES[@]}"; do
        if grep -v "^[[:space:]]*#" /etc/fstab | grep -qE "[[:space:]]+${bm}[[:space:]]+"; then
            if ! mountpoint -q "$bm"; then
                log "ERROR" "$bm is defined in fstab but NOT mounted. Aborting to prevent data corruption."
                exit 1
            fi
        fi
    done

    # Select Destination
    while true; do
        echo -e "\nEnter DESTINATION disk name (e.g., sdb, sdc): "
        read -r dst_name
        DST_DEVICE="/dev/$dst_name"

        if [[ ! -b "$DST_DEVICE" ]]; then
            echo "Error: Invalid device $DST_DEVICE"
            continue
        fi

        if [[ "$SRC_DEVICE" == "$DST_DEVICE" ]]; then
            echo "Error: Source and destination cannot be the same!"
            continue
        fi
        break
    done

    # Detect Source Layout to replicate it
    SRC_TABLE_TYPE=$(detect_partition_table "$SRC_DEVICE")
    log "INFO" "Detected Source Partition Table: $SRC_TABLE_TYPE"
    
    # Define Destination Partitions
    DST_PART1=$(get_partition_device "$DST_DEVICE" 1)
    DST_PART2=$(get_partition_device "$DST_DEVICE" 2)
}

# Perform a full backup (Wipe -> Partition -> Format -> Sync)
perform_full_backup() {
    log "INFO" "=== Performing Full Backup ==="
    log "INFO" "Target Layout: $SRC_TABLE_TYPE (Matching Source)"
    
    # 0. Check Space
    # We check if the USED space on source fits on destination (plus margin).
    # This allows cloning to a smaller drive as long as data fits.
    local boot_mount_point
    boot_mount_point=$(detect_boot_mount)
    check_space "/" "$boot_mount_point" "$DST_DEVICE"

    # 1. Wipe and Partition
    # We recreate the partition table to match the source type (MBR or GPT).
    log "INFO" "Wiping existing signatures..."
    wipefs -a "$DST_DEVICE" || true # Force wipe, ignore errors if empty
    
    log "INFO" "Creating partition table..."
    if [[ "$SRC_TABLE_TYPE" == "gpt" ]]; then
        # x86/UEFI Standard: GPT
        parted -s -a optimal "$DST_DEVICE" mklabel gpt
        # ESP (EFI System Partition) - 1024MB (Future proofing)
        # Start at 1MiB to protect MBR/Bootloader area
        parted -s -a optimal "$DST_DEVICE" mkpart "EFI" fat32 1MiB 1025MiB
        parted -s -a optimal "$DST_DEVICE" set 1 esp on
        # Root - Rest of disk
        parted -s -a optimal "$DST_DEVICE" mkpart "Root" ext4 1025MiB 100%
    else
        # RPi/Legacy Standard: MBR (msdos)
        parted -s -a optimal "$DST_DEVICE" mklabel msdos
        # Boot - 1024MB (Fat32)
        parted -s -a optimal "$DST_DEVICE" mkpart primary fat32 1MiB 1025MiB
        # Root - Rest of disk
        parted -s -a optimal "$DST_DEVICE" mkpart primary ext4 1025MiB 100%
    fi

    # Force kernel to reread partition table
    # We allow failure here (|| true) because on some systems partprobe fails if devices are busy,
    # but we verify actual availability with udevadm settle and the loop below.
    partprobe "$DST_DEVICE" || true
    udevadm settle # Wait for udev to process events

    # Wait for partition nodes to appear (defensive)
    local timeout=20
    while [[ ! -b "$DST_PART1" || ! -b "$DST_PART2" ]]; do
        if (( timeout-- == 0 )); then
            log "ERROR" "Timed out waiting for partition devices to appear."
            exit 1
        fi
        sleep 1
    done

    # 2. Format
    log "INFO" "Formatting partitions..."
    mkfs.vfat -F 32 -n "BOOT" "$DST_PART1"
    mkfs.ext4 -F "${EXT4_OPTIONS[@]}" -i "$INODE_RATIO" -L "rootfs" "$DST_PART2"
    
    # Wait for UUIDs to settle after formatting
    udevadm settle

    # 3. Mount
    mount_destination

    # 4. Copy Data
    sync_data

    # 5. Update Configs (UUIDs)
    # This is critical: since we formatted new partitions, they have NEW UUIDs.
    # We must update fstab/cmdline on the destination to match.
    update_destination_config
    
    # 6. Recreate Swap
    recreate_swap
    
    # 7. Verify
    verify_backup

    log "INFO" "Full backup completed successfully."
}

# Perform incremental update (Sync -> Config Check)
# Only updates changed files, much faster than full backup.
perform_incremental_update() {
    log "INFO" "=== Performing Incremental Update ==="
    
    # 1. Check Filesystem Health (Dirty Check)
    # Ensure destination is clean before mounting to avoid mount failures
    # CRITICAL: Partitions MUST NOT be mounted during fsck!
    log "INFO" "Checking destination filesystem health..."
    
    for part in "$DST_PART1" "$DST_PART2"; do
        if grep -qs "$part" /proc/mounts; then
            log "WARN" "$part is currently mounted. Attempting to unmount for fsck..."
            umount "$part" || {
                log "WARN" "Could not unmount $part. Skipping fsck to prevent corruption."
                continue
            }
        fi
        fsck -y "$part" || log "WARN" "fsck on $part returned error, proceeding anyway..."
    done

    # 2. Mount
    mount_destination

    # 3. Copy Data
    sync_data

    # 4. Update Configs
    # We run this even on incremental updates to ensure config is consistent
    # if fstab changed on source or if we are fixing a broken backup.
    update_destination_config

    # 5. Verify
    verify_backup

    log "INFO" "Incremental update completed successfully."
}

# Mount destination partitions to temporary directory
mount_destination() {
    DST_MOUNT_ROOT=$(mktemp -d)
    log "INFO" "Mounting root to $DST_MOUNT_ROOT..."
    mount "$DST_PART2" "$DST_MOUNT_ROOT"
    MOUNTED_BY_SCRIPT+=("$DST_MOUNT_ROOT")

    # Determine boot mount point based on ACTIVE mounts
    BOOT_MOUNT=$(detect_boot_mount)

    log "INFO" "Mounting boot to $DST_MOUNT_ROOT$BOOT_MOUNT..."
    mkdir -p "$DST_MOUNT_ROOT$BOOT_MOUNT"

    # Ensure mountpoint is empty before mounting (avoid hiding files)
    # Use compgen glob instead of ls subshell
    if compgen -G "$DST_MOUNT_ROOT$BOOT_MOUNT/*" >/dev/null 2>&1; then
        log "WARN" "Mountpoint $DST_MOUNT_ROOT$BOOT_MOUNT is not empty. Cleaning..."
        rm -rf "${DST_MOUNT_ROOT:?}${BOOT_MOUNT:?}"/*
    fi

    mount "$DST_PART1" "$DST_MOUNT_ROOT$BOOT_MOUNT"
    MOUNTED_BY_SCRIPT+=("$DST_MOUNT_ROOT$BOOT_MOUNT")
}

# Sync filesystem data using rsync
sync_data() {
    log "INFO" "Syncing Root Filesystem..."
    # Construct exclude arguments from array
    # We use a filter strategy to preserve directory structures for logs and cache
    # while excluding their content.
    local rsync_args=()
    
    # 1. Include directories for specific paths we want to empty but keep
    rsync_args+=(--include="/var/log/*/")
    rsync_args+=(--include="/var/cache/*/")
    rsync_args+=(--include="/var/tmp/*/")
    rsync_args+=(--include="/tmp/*/")
    
    # 2. Exclude content of those paths
    rsync_args+=(--exclude="/var/log/*")
    rsync_args+=(--exclude="/var/cache/*")
    rsync_args+=(--exclude="/var/tmp/*")
    rsync_args+=(--exclude="/tmp/*")
    
    # Protect lost+found from deletion on destination
    rsync_args+=(--filter='protect /lost+found')
    
    # Dynamic exclude for boot partition (prevents error 23 on FAT32)
    # We exclude the mountpoint itself so rsync doesn't try to set permissions on it
    if [[ -n "$BOOT_MOUNT" ]]; then
        rsync_args+=(--exclude="${BOOT_MOUNT}")
    fi
    
    # 3. General excludes
    for excl in "${EXCLUDES[@]}"; do
        # Skip the ones we handled manually above to avoid conflicts
        if [[ "$excl" == "/var/log/*" ]] || [[ "$excl" == "/var/cache/*" ]] || [[ "$excl" == "/var/tmp/*" ]] || [[ "$excl" == "/tmp/*" ]]; then
            continue
        fi
        rsync_args+=(--exclude="$excl")
    done

    # Sync Root
    # -a: archive mode (preserves permissions, times, etc.)
    # -H: preserve hard links
    # -A: preserve ACLs
    # -X: preserve extended attributes
    # -x: don't cross filesystem boundaries (stay on root)
    # --delete: delete files on dest that are gone on source
    # We allow exit code 24 (vanished files) which is common on live systems
    # Capture exit code without set +e (which is fragile with ERR traps)
    local rsync_exit=0
    rsync -aHAXx --numeric-ids --info=progress2 --delete \
        "${rsync_args[@]}" \
        / "$DST_MOUNT_ROOT/" || rsync_exit=$?

    if [[ $rsync_exit -eq 0 ]]; then
        log "INFO" "Root sync completed successfully."
    elif [[ $rsync_exit -eq 24 ]]; then
        log "WARN" "Rsync reported vanished files (code 24). This is normal on a live system."
    else
        log "ERROR" "Rsync failed with error code $rsync_exit"
        exit $rsync_exit
    fi

    log "INFO" "Syncing Boot Partition..."
    
    # Use global BOOT_MOUNT determined in mount_destination
    SRC_BOOT="$BOOT_MOUNT/"
    DST_BOOT="$DST_MOUNT_ROOT$BOOT_MOUNT/"

    # Sync Boot Partition
    # Use specific flags for VFAT/FAT32:
    # --no-perms, --no-owner, --no-group: FAT doesn't support these
    # --copy-links: FAT doesn't support symlinks, so we copy the content
    # --modify-window=2: FAT has 2s timestamp resolution
    rsync -rt --no-perms --no-owner --no-group --copy-links --info=progress2 --delete --modify-window=2 \
        "$SRC_BOOT" "$DST_BOOT"
}

# Update destination configuration files (fstab, cmdline.txt)
# This ensures the cloned system boots by using the correct NEW UUIDs.
update_destination_config() {
    log "INFO" "Updating destination configuration (fstab/cmdline)..."
    
    # Retrieve NEW UUIDs/PARTUUIDs from the freshly formatted destination
    local new_root_uuid
    new_root_uuid=$(get_uuid "$DST_PART2")
    local new_boot_uuid
    new_boot_uuid=$(get_uuid "$DST_PART1")
    local new_root_partuuid
    new_root_partuuid=$(get_partuuid "$DST_PART2")
    local new_boot_partuuid
    new_boot_partuuid=$(get_partuuid "$DST_PART1")

    local dst_fstab="$DST_MOUNT_ROOT/etc/fstab"
    local dst_cmdline="$DST_MOUNT_ROOT/boot/firmware/cmdline.txt" # RPi specific

    # Sanitize BOOT_MOUNT (remove trailing slash) for awk comparison
    local boot_mount_clean="${BOOT_MOUNT%/}"

    # 1. Update fstab
    if [[ -f "$dst_fstab" ]]; then
        log "INFO" "Patching $dst_fstab..."
        
        # Create a backup of the original fstab
        cp "$dst_fstab" "${dst_fstab}.bak"

        # Use awk to surgically replace the UUID/PARTUUID (field 1) for root and boot entries
        # while preserving all other fields (mount options, dump, pass) and other entries.
        awk -v new_root_uuid="$new_root_uuid" \
            -v new_root_partuuid="$new_root_partuuid" \
            -v new_boot_uuid="$new_boot_uuid" \
            -v new_boot_partuuid="$new_boot_partuuid" \
            -v boot_mount="$boot_mount_clean" \
            -v table_type="$SRC_TABLE_TYPE" '
        BEGIN { OFS="\t" }
        {
            # Skip comments and empty lines
            if ($0 ~ /^[[:space:]]*#/ || $0 == "") {
                print $0
                next
            }

            # Normalize mount point (remove trailing slash if present, but keep root /)
            mount_point = $2
            if (length(mount_point) > 1) sub(/\/$/, "", mount_point)

            # Handle Root Partition (Mount point is /)
            if (mount_point == "/") {
                if (table_type == "gpt") {
                    $1 = "UUID=" new_root_uuid
                } else {
                    $1 = "PARTUUID=" new_root_partuuid
                }
            }
            # Handle Boot Partition
            else if (mount_point == boot_mount) {
                if (table_type == "gpt") {
                    $1 = "UUID=" new_boot_uuid
                } else {
                    $1 = "PARTUUID=" new_boot_partuuid
                }
            }
            print $0
        }' "${dst_fstab}.bak" > "$dst_fstab"
        
        # Remove the backup file to keep the clone clean
        rm "${dst_fstab}.bak"
    fi

    # 2. Update cmdline.txt (RPi only)
    # The RPi bootloader uses this file to know which partition to mount as root.
    if [[ -f "$dst_cmdline" ]]; then
        log "INFO" "Patching $dst_cmdline..."
        # Replace any existing root= parameter with the new PARTUUID
        sed -E -i "s/root=[^ ]+/root=PARTUUID=$new_root_partuuid/g" "$dst_cmdline"
    fi

    # 3. Update systemd-boot entries (x86/Arch specific)
    # systemd-boot uses config files in loader/entries/*.conf which specify the root partition.
    # Try primary path first, then fallback (loader sometimes in /boot/loader even if EFI is /boot/efi)
    local loader_entries_dir="$DST_MOUNT_ROOT$BOOT_MOUNT/loader/entries"
    local alt_loader_dir="$DST_MOUNT_ROOT/boot/loader/entries"

    _patch_loader_entries "$loader_entries_dir" "$new_root_partuuid" ||
        _patch_loader_entries "$alt_loader_dir" "$new_root_partuuid" || true

    # 4. Check for GRUB (Warning only)
    # This script does not currently support patching GRUB automatically, as it requires
    # complex chroot/update-grub operations that vary by distro.
    if [[ -f "$DST_MOUNT_ROOT/boot/grub/grub.cfg" ]] || [[ -f "$DST_MOUNT_ROOT/boot/grub2/grub.cfg" ]]; then
        log "WARN" "----------------------------------------------------------------"
        log "WARN" "GRUB configuration detected!"
        log "WARN" "This script updated UUIDs in fstab, but GRUB configuration (grub.cfg)"
        log "WARN" "likely still references the OLD UUIDs."
        log "WARN" "The cloned system MAY NOT BOOT until you reinstall GRUB or update"
        log "WARN" "grub.cfg on the destination drive."
        log "WARN" "----------------------------------------------------------------"
    fi
}

# Recreate swapfile if it existed on source
recreate_swap() {
    # Check for Swap Partitions (not supported)
    if grep -v "^[[:space:]]*#" /etc/fstab | grep -q "swap"; then
        # Check if it's a partition (starts with UUID=, PARTUUID=, /dev/) not a file
        if grep -v "^[[:space:]]*#" /etc/fstab | grep "swap" | grep -qE "^(UUID|PARTUUID|/dev)"; then
             log "WARN" "----------------------------------------------------------------"
             log "WARN" "Detected a SWAP PARTITION in /etc/fstab."
             log "WARN" "This script only supports cloning SWAP FILES."
             log "WARN" "The swap partition will NOT be created on the destination."
             log "WARN" "The cloned system will boot, but without swap."
             log "WARN" "----------------------------------------------------------------"
        fi
    fi

    local swapfile="/swapfile"
    if [[ -f "$swapfile" ]]; then
        log "INFO" "Detected swapfile on source. Recreating on destination..."
        local swap_size
        swap_size=$(stat -c %s "$swapfile")
        
        # Create swapfile using dd for physical allocation
        # fallocate can create holes which some kernels/filesystems dislike for swap
        local swap_mb=$(( (swap_size + 1048575) / 1048576 ))
        log "INFO" "Allocating ${swap_mb}MB for swapfile..."

        if dd if=/dev/zero of="$DST_MOUNT_ROOT$swapfile" bs=1M count="$swap_mb"; then
            # Truncate to exact size if needed
            truncate -s "$swap_size" "$DST_MOUNT_ROOT$swapfile"
            
            chmod 600 "$DST_MOUNT_ROOT$swapfile"
            mkswap "$DST_MOUNT_ROOT$swapfile" >/dev/null
            log "INFO" "Swapfile recreated successfully ($(numfmt --to=iec-i --suffix=B "$swap_size"))."
        else
            log "WARN" "Failed to recreate swapfile (dd failed). Skipping."
        fi
    fi
}

# Verify the backup configuration
verify_backup() {
    log "INFO" "=== Verifying Backup Configuration ==="

    local root_uuid
    root_uuid=$(get_uuid "$DST_PART2")
    local root_partuuid
    root_partuuid=$(get_partuuid "$DST_PART2")

    # Check fstab (ignore comments) — use grep -F for fixed-string matching (no regex injection)
    if grep -v "^[[:space:]]*#" "$DST_MOUNT_ROOT/etc/fstab" | grep -qF -e "$root_uuid" -e "$root_partuuid"; then
        log "INFO" "[PASS] fstab contains new Root UUID/PARTUUID"
    else
        log "ERROR" "[FAIL] fstab missing new Root UUID/PARTUUID!"
    fi

    # Check cmdline.txt (if exists)
    if [[ -f "$DST_MOUNT_ROOT/boot/firmware/cmdline.txt" ]]; then
         if grep -qF "$root_partuuid" "$DST_MOUNT_ROOT/boot/firmware/cmdline.txt"; then
            log "INFO" "[PASS] cmdline.txt updated with new Root PARTUUID"
         else
            log "ERROR" "[FAIL] cmdline.txt missing new Root PARTUUID!"
         fi
    fi

    # Check systemd-boot entries (primary path, then fallback)
    local loader_entries_dir="$DST_MOUNT_ROOT$BOOT_MOUNT/loader/entries"
    local alt_loader_dir="$DST_MOUNT_ROOT/boot/loader/entries"

    _verify_loader_entries "$loader_entries_dir" "$root_uuid" "$root_partuuid" "" ||
        _verify_loader_entries "$alt_loader_dir" "$root_uuid" "$root_partuuid" "(fallback)" || true
}

###################
# Main Execution
###################

check_root
check_dependencies

select_disks

echo "=============================================="
echo " Source:      $SRC_DEVICE ($SRC_TABLE_TYPE)"
echo " Destination: $DST_DEVICE"
echo "=============================================="
echo "WARNING: ALL DATA ON $DST_DEVICE WILL BE ERASED!"
echo "=============================================="

# Check if destination looks like an existing backup
# We check if partitions exist and if we can mount root and find an fstab.
declare is_backup=false
if [[ -b "$DST_PART1" ]] && [[ -b "$DST_PART2" ]]; then
    declare tmp_check
    tmp_check=$(mktemp -d)
    if mount "$DST_PART2" "$tmp_check" 2>/dev/null; then
        if [[ -f "$tmp_check/etc/fstab" ]]; then
            is_backup=true
        fi
        umount "$tmp_check"
    fi
    rm -rf "$tmp_check"
fi

if [[ "$is_backup" == true ]]; then
    log "INFO" "Destination appears to be an existing system/backup."
    read -p "Perform INCREMENTAL update? (y/n - 'n' triggers FULL wipe): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        perform_incremental_update
        exit 0
    fi
fi

read -p "Perform FULL BACKUP (Wipe & Clone)? (yes/no): " -r
if [[ $REPLY =~ ^yes$ ]]; then
    perform_full_backup
else
    log "WARN" "Aborted."
    exit 0
fi

exit 0