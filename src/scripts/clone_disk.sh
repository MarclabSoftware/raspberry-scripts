#!/bin/bash

# =============================================================================
# Raspberry Pi System Backup Script
# =============================================================================
#
# Creates an exact bootable clone of a Raspberry Pi system from one media to another.
# Maintains all partition UUIDs and filesystem attributes for direct replacement.
#
# Requirements:
# - Two disks
# - Root privileges
# - Required tools: rsync, mkfs.vfat, mkfs.ext4, fsck tools
#
# Warning: This script will completely erase the destination drive!
#
# Author: LaboDJ
# Version: 1.1
# Last Updated: 2025/01/21
# =============================================================================

# Enable exit on error
set -e

# Helper Functions
# -----------------------------------------------------------------------------

# Verifies if a block device exists
# Args: $1 - device path
check_device() {
    if [ ! -b "$1" ]; then
        echo "Error: Device $1 not found!"
        exit 1
    fi
}

# Verifies if a path is properly mounted
# Args: $1 - mount point to check
verify_mount() {
    if ! mountpoint -q "$1"; then
        echo "Error: Failed to mount $1"
        exit 1
    fi
}

# Safely unmounts a filesystem with fallback to lazy unmount
# Args: $1 - mount point to unmount
safe_unmount() {
    local mount_point="$1"
    if mountpoint -q "$mount_point"; then
        umount "$mount_point" || {
            echo "Failed to unmount $mount_point, retrying with lazy unmount..."
            umount -l "$mount_point"
        }
    fi
}

# Verifies if a command is available in the system
# Args: $1 - command to check
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Checks if destination has enough space for the backup
# Args: $1 - source path, $2 - destination path
check_space() {
    local src=$1
    local dst=$2
    local src_size
    local dst_size

    src_size="$(df -B1 "$src" | awk 'NR==2 {print $3}')"
    dst_size="$(df -B1 "$dst" | awk 'NR==2 {print $2}')"

    if [ "$dst_size" -lt "$src_size" ]; then
        echo "Error: Destination device doesn't have enough space!"
        echo "Source size: $(numfmt --to=iec-i --suffix=B "$src_size")"
        echo "Destination size: $(numfmt --to=iec-i --suffix=B "$dst_size")"
        exit 1
    fi
}

# Displays a progress bar during the backup process
# Args: $1 - process ID to monitor
show_progress() {
    local pid=$1
    local src_size
    local dst_used
    local progress

    src_size="$(df -B1 / | awk 'NR==2 {print $3}')"

    while kill -0 "$pid" 2>/dev/null; do
        dst_used="$(df -B1 "$DST_MOUNT_ROOT" | awk 'NR==2 {print $3}')"
        progress=$((dst_used * 100 / src_size))
        echo -ne "Progress: $progress% \r"
        sleep 1
    done
    echo -ne '\n'
}

# Check if destination disk is already a backup
# Returns 0 if it's a backup, 1 if it's not
check_if_backup() {
    local src_partuuid_1 src_partuuid_2 dst_partuuid_1 dst_partuuid_2

    # Check if destination partitions exist
    if [ ! -b "${DST_DEVICE}1" ] || [ ! -b "${DST_DEVICE}2" ]; then
        return 1
    fi

    # Get PARTUUIDs
    src_partuuid_1=$(blkid -s PARTUUID -o value "${SRC_DEVICE}1")
    src_partuuid_2=$(blkid -s PARTUUID -o value "${SRC_DEVICE}2")
    dst_partuuid_1=$(blkid -s PARTUUID -o value "${DST_DEVICE}1")
    dst_partuuid_2=$(blkid -s PARTUUID -o value "${DST_DEVICE}2")

    # Compare PARTUUIDs
    if [ "$src_partuuid_1" = "$dst_partuuid_1" ] && [ "$src_partuuid_2" = "$dst_partuuid_2" ]; then
        return 0
    else
        return 1
    fi
}

# Perform incremental update of backup
perform_incremental_update() {
    echo "Performing incremental update of existing backup..."

    # Mount destination partitions
    mount "${DST_DEVICE}2" "$DST_MOUNT_ROOT"
    verify_mount "$DST_MOUNT_ROOT"

    mkdir -p "$DST_MOUNT_ROOT/boot/firmware"
    mount "${DST_DEVICE}1" "$DST_MOUNT_ROOT/boot/firmware"
    verify_mount "$DST_MOUNT_ROOT/boot/firmware"

    # Check space
    check_space "/" "$DST_MOUNT_ROOT"

    # Update root filesystem
    echo "Updating root filesystem..."
    rsync -aHAXx --numeric-ids --info=progress2 \
        --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/boot/firmware/*"} \
        --exclude="/var/cache/apt/archives/*" \
        --exclude="/var/log/*" \
        --exclude="/var/tmp/*" \
        --exclude="*.log" \
        --exclude="*.tmp" \
        --exclude="*.pid" \
        --exclude="*.swp" \
        --delete \
        --compress \
        --compress-level=1 \
        / "$DST_MOUNT_ROOT/" &

    RSYNC_PID=$!
    show_progress $RSYNC_PID
    wait $RSYNC_PID

    # Update firmware partition
    echo "Updating firmware partition..."
    rsync -aHAXx --numeric-ids --info=progress2 \
        --compress \
        --compress-level=1 \
        /boot/firmware/ "$DST_MOUNT_ROOT/boot/firmware/"

    # Verify data integrity
    echo "Verifying data integrity..."
    if ! rsync -avn --delete / "$DST_MOUNT_ROOT/" | grep -q "^$"; then
        echo "Warning: Differences found in root filesystem!"
        return 1
    fi

    if ! rsync -avn --delete /boot/firmware/ "$DST_MOUNT_ROOT/boot/firmware/" | grep -q "^$"; then
        echo "Warning: Differences found in firmware partition!"
        return 1
    fi

    # Sync and unmount
    echo "Syncing filesystems..."
    sync

    echo "Unmounting destination partitions..."
    safe_unmount "$DST_MOUNT_ROOT/boot/firmware"
    safe_unmount "$DST_MOUNT_ROOT"

    return 0
}

# List available disks and let user select source and destination
select_disks() {
    echo "Available disks:"
    lsblk -d -o NAME,SIZE,MODEL | grep -E "sd|nvme|mmcblk"

    while true; do
        echo -e "\nEnter source disk name (e.g., sda, nvme0n1): "
        read -r SRC_DISK
        if [ ! -b "/dev/$SRC_DISK" ]; then
            echo "Error: Invalid disk /dev/$SRC_DISK"
            continue
        fi

        # Verify if source disk is the system disk
        if ! grep -q "/dev/${SRC_DISK}2 / " /proc/mounts; then
            echo "Warning: /dev/$SRC_DISK doesn't appear to be the system disk!"
            read -p "Are you sure this is the correct source disk? (yes/no) " -r
            if [[ ! $REPLY =~ ^yes$ ]]; then
                continue
            fi
        fi
        break
    done

    while true; do
        echo -e "\nEnter destination disk name (e.g., sdb, nvme1n1): "
        read -r DST_DISK
        if [ ! -b "/dev/$DST_DISK" ]; then
            echo "Error: Invalid disk /dev/$DST_DISK"
            continue
        fi

        if [ "$SRC_DISK" = "$DST_DISK" ]; then
            echo "Error: Source and destination cannot be the same disk!"
            continue
        fi
        break
    done

    # Export variables for use in main script
    SRC_DEVICE="/dev/$SRC_DISK"
    DST_DEVICE="/dev/$DST_DISK"
}

# Perform full backup
perform_full_backup() {
    echo "Performing full backup..."

    # 1. Create exact copy of partition table including PARTUUIDs
    echo "Creating exact partition table copy..."
    dd if="$SRC_DEVICE" of="$DST_DEVICE" bs=1M count=4 conv=fsync status=progress

    # Wait for kernel to update partition table
    sleep 2
    partprobe "$DST_DEVICE"

    # 2. Create filesystems with same parameters
    echo "Creating filesystems..."

    # Verify that partitions exist and are not mounted
    for part in "${DST_DEVICE}1" "${DST_DEVICE}2"; do
        if [ ! -b "$part" ]; then
            echo "Error: Partition $part not found. Waiting 5 seconds for device..."
            sleep 5
            if [ ! -b "$part" ]; then
                echo "Error: Partition $part still not found"
                return 1
            fi
        fi

        if mountpoint -q "$part" || grep -q "^$part " /proc/mounts; then
            echo "Error: $part is still mounted!"
            return 1
        fi
    done

    # Create FAT filesystem on first partition
    echo "Creating FAT filesystem on ${DST_DEVICE}1..."
    if ! mkfs.vfat "${DST_DEVICE}1"; then
        echo "Error creating FAT filesystem on ${DST_DEVICE}1"
        return 1
    fi

    # Create optimized ext4 filesystem on second partition
    echo "Creating ext4 filesystem on ${DST_DEVICE}2..."
    if ! mkfs.ext4 -F \
        -O has_journal,extent,flex_bg,metadata_csum,64bit,dir_nlink,extra_isize \
        -E lazy_itable_init=0,lazy_journal_init=0,discard \
        -b 4096 \
        -I 256 \
        -i 32768 \
        -m 0 \
        -J size=64 \
        -L rootfs \
        "${DST_DEVICE}2"; then
        echo "Error creating ext4 filesystem on ${DST_DEVICE}2"
        return 1
    fi

    # Mount and perform backup
    mount "${DST_DEVICE}2" "$DST_MOUNT_ROOT"
    verify_mount "$DST_MOUNT_ROOT"

    mkdir -p "$DST_MOUNT_ROOT/boot/firmware"
    mount "${DST_DEVICE}1" "$DST_MOUNT_ROOT/boot/firmware"
    verify_mount "$DST_MOUNT_ROOT/boot/firmware"

    # Perform the actual backup using rsync
    echo "Copying root filesystem..."
    rsync -aHAXx --numeric-ids --info=progress2 \
        --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/boot/firmware/*"} \
        --exclude="/var/cache/apt/archives/*" \
        --exclude="/var/log/*" \
        --exclude="/var/tmp/*" \
        --exclude="*.log" \
        --exclude="*.tmp" \
        --exclude="*.pid" \
        --exclude="*.swp" \
        --delete \
        --compress \
        --compress-level=1 \
        / "$DST_MOUNT_ROOT/" &

    RSYNC_PID=$!
    show_progress $RSYNC_PID
    wait $RSYNC_PID

    echo "Copying firmware partition..."
    rsync -aHAXx --numeric-ids --info=progress2 \
        --compress \
        --compress-level=1 \
        /boot/firmware/ "$DST_MOUNT_ROOT/boot/firmware/"

    # Sync and unmount
    echo "Syncing filesystems..."
    sync

    echo "Unmounting destination partitions..."
    safe_unmount "$DST_MOUNT_ROOT/boot/firmware"
    safe_unmount "$DST_MOUNT_ROOT"

    return 0
}

# Check required commands
check_required_commands() {
    local required_commands=(
        "rsync"
        "mkfs.vfat"
        "mkfs.ext4"
        "fsck.vfat"
        "e2fsck"
        "blkid"
        "dd"
        "partprobe"
        "mountpoint"
        "lsblk"
        "grep"
        "awk"
    )

    local missing_commands=()
    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        echo "Error: Required commands not found:"
        printf '%s\n' "${missing_commands[@]}"
        echo "Please install the missing packages and try again."
        exit 1
    fi
}

# Main Script
# -----------------------------------------------------------------------------

# Check if script is run as root
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root!"
    exit 1
fi

# Check for required commands
check_required_commands

# Create temporary mount points
DST_MOUNT_ROOT=$(mktemp -d)

# Cleanup function
# shellcheck disable=SC2317
cleanup() {
    echo "Cleaning up..."
    safe_unmount "$DST_MOUNT_ROOT/boot/firmware"
    safe_unmount "$DST_MOUNT_ROOT"
    rm -rf "$DST_MOUNT_ROOT"
}

trap cleanup EXIT

# Call the disk selection function
select_disks

# Check devices
check_device "$SRC_DEVICE"
check_device "$DST_DEVICE"

# Verify source device is correct
if ! grep -q "${SRC_DEVICE}2 / " /proc/mounts; then
    echo "Error: ${SRC_DEVICE}2 is not mounted as root! Aborting for safety."
    exit 1
fi

# Check if destination is already a backup
if check_if_backup; then
    echo "Destination disk appears to be an existing backup."
    read -p "Would you like to perform an incremental update? (yes/no) " -r
    if [[ $REPLY =~ ^yes$ ]]; then
        if perform_incremental_update; then
            echo "Incremental update completed successfully!"
        else
            echo "Error during incremental update!"
            exit 1
        fi
    else
        read -p "Would you like to perform a full backup instead? (yes/no) " -r
        if [[ $REPLY =~ ^yes$ ]]; then
            if perform_full_backup; then
                echo "Full backup completed successfully!"
            else
                echo "Error during full backup!"
                exit 1
            fi
        else
            echo "Aborting."
            exit 0
        fi
    fi
else
    echo "Destination disk is not a backup. Performing full backup..."
    if perform_full_backup; then
        echo "Full backup completed successfully!"
    else
        echo "Error during full backup!"
        exit 1
    fi
fi

exit 0
