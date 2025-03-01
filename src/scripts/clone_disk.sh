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
# Version: 1.2
# Last Updated: 2025/02/28
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

# Copy root filesystem
# Args: $1 - destination mount point
copy_root_filesystem() {
    local dst_mount="$1"
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
        / "$dst_mount/" &

    RSYNC_PID=$!
    show_progress $RSYNC_PID
    wait $RSYNC_PID
}

# Copy firmware partition
# Args: $1 - destination firmware mount point
copy_firmware_partition() {
    local dst_firmware="$1"
    echo "Copying firmware partition..."
    rsync -aHAXx --numeric-ids --info=progress2 \
        --compress \
        --compress-level=1 \
        /boot/firmware/ "$dst_firmware/"
}

# Verify filesystem integrity
# Args: $1 - destination mount point
verify_filesystem_integrity() {
    local dst_mount="$1"
    echo "Verifying data integrity..."

    if ! rsync -avn --delete / "$dst_mount/" | grep -q "^$"; then
        echo "Warning: Differences found in root filesystem!"
        return 1
    fi

    if ! rsync -avn --delete /boot/firmware/ "$dst_mount/boot/firmware/" | grep -q "^$"; then
        echo "Warning: Differences found in firmware partition!"
        return 1
    fi

    return 0
}

# Check if destination disk is already a backup
# Returns 0 if it's a backup, 1 if it's not
check_if_backup() {
    local src_partuuid_1 src_partuuid_2 dst_partuuid_1 dst_partuuid_2

    # Check if destination partitions exist
    if [ ! -b "$DST_PART1" ] || [ ! -b "$DST_PART2" ]; then
        return 1
    fi

    # Get PARTUUIDs
    src_partuuid_1=$(blkid -s PARTUUID -o value "$SRC_PART1")
    src_partuuid_2=$(blkid -s PARTUUID -o value "$SRC_PART2")
    dst_partuuid_1=$(blkid -s PARTUUID -o value "$DST_PART1")
    dst_partuuid_2=$(blkid -s PARTUUID -o value "$DST_PART2")

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
    mount "$DST_PART2" "$DST_MOUNT_ROOT"
    verify_mount "$DST_MOUNT_ROOT"

    mkdir -p "$DST_MOUNT_ROOT/boot/firmware"
    mount "$DST_PART1" "$DST_MOUNT_ROOT/boot/firmware"
    verify_mount "$DST_MOUNT_ROOT/boot/firmware"

    # Check space
    check_space "/" "$DST_MOUNT_ROOT"

    # Copy filesystems
    copy_root_filesystem "$DST_MOUNT_ROOT"
    copy_firmware_partition "$DST_MOUNT_ROOT/boot/firmware"

    # Verify integrity
    verify_filesystem_integrity "$DST_MOUNT_ROOT"

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
        if ! grep -q "/dev/${SRC_DISK}2 / " /proc/mounts && ! grep -q "/dev/${SRC_DISK}p2 / " /proc/mounts; then
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

    # Determine partition names based on device type
    if [[ "$SRC_DISK" == nvme* ]]; then
        SRC_PART1="${SRC_DEVICE}p1"
        SRC_PART2="${SRC_DEVICE}p2"
    else
        SRC_PART1="${SRC_DEVICE}1"
        SRC_PART2="${SRC_DEVICE}2"
    fi

    if [[ "$DST_DISK" == nvme* ]]; then
        DST_PART1="${DST_DEVICE}p1"
        DST_PART2="${DST_DEVICE}p2"
    else
        DST_PART1="${DST_DEVICE}1"
        DST_PART2="${DST_DEVICE}2"
    fi
}

# Perform full backup
perform_full_backup() {
    echo "Performing full backup..."
    local src_part2_used dst_disk_size src_disk_id

    # Get source partition sizes and disk ID
    src_part2_used=$(df -B1 "$SRC_PART2" | awk 'NR==2 {print $3}')
    dst_disk_size=$(blockdev --getsize64 "$DST_DEVICE")
    src_disk_id=$(sfdisk --disk-id "$SRC_DEVICE")

    # Check if destination disk has enough space
    local required_size=$((1024 * 1024 * 1024 + src_part2_used + (50 * 1024 * 1024)))
    if [ "$dst_disk_size" -lt "$required_size" ]; then
        echo "Error: Destination disk is too small!"
        echo "Required space: $(numfmt --to=iec-i --suffix=B "$required_size")"
        echo "Available space: $(numfmt --to=iec-i --suffix=B "$dst_disk_size")"
        return 1
    fi

    # Create new MBR partition table
    echo "Creating new MBR partition table..."
    parted -s "$DST_DEVICE" mklabel msdos

    # Create partitions with fixed sizes
    echo "Creating partitions..."
    parted -s "$DST_DEVICE" mkpart primary fat32 0G 1G
    parted -s "$DST_DEVICE" mkpart primary ext4 1G 100%

    # Force kernel to reread partition table
    echo "Updating partition table..."
    partprobe "$DST_DEVICE"

    # Wait for partition devices to appear
    echo "Waiting for partition devices..."
    for i in {1..10}; do
        if [ -b "$DST_PART1" ] && [ -b "$DST_PART2" ]; then
            break
        fi
        echo "Waiting for partitions to appear (attempt $i/10)..."
        sleep 1
        partprobe "$DST_DEVICE"
    done

    # Final check for partition devices
    if [ ! -b "$DST_PART1" ] || [ ! -b "$DST_PART2" ]; then
        echo "Error: Partition devices did not appear after waiting!"
        return 1
    fi

    # Create filesystems
    echo "Creating FAT32 filesystem on first partition..."
    mkfs.vfat "$DST_PART1"

    echo "Creating ext4 filesystem on second partition..."
    mkfs.ext4 -F \
        -O has_journal,extent,flex_bg,metadata_csum,64bit,dir_nlink,extra_isize \
        -E lazy_itable_init=0,lazy_journal_init=0,discard \
        -b 4096 \
        -I 256 \
        -i 32768 \
        -m 0 \
        -J size=64 \
        -L rootfs \
        "$DST_PART2"

    # Mount and perform backup
    mount "$DST_PART2" "$DST_MOUNT_ROOT"
    verify_mount "$DST_MOUNT_ROOT"

    mkdir -p "$DST_MOUNT_ROOT/boot/firmware"
    mount "$DST_PART1" "$DST_MOUNT_ROOT/boot/firmware"
    verify_mount "$DST_MOUNT_ROOT/boot/firmware"

    # Copy filesystems
    copy_root_filesystem "$DST_MOUNT_ROOT"
    copy_firmware_partition "$DST_MOUNT_ROOT/boot/firmware"

    # Sync filesystems
    echo "Syncing filesystems..."
    sync

    # Unmount before setting disk ID
    echo "Unmounting destination partitions..."
    safe_unmount "$DST_MOUNT_ROOT/boot/firmware"
    safe_unmount "$DST_MOUNT_ROOT"

    # Set the disk ID to match the source
    echo "Setting disk ID to match source..."
    sfdisk --disk-id "$DST_DEVICE" "$src_disk_id"

    return 0
}
# Main script execution
# -----------------------------------------------------------------------------

# Check required commands
check_required_commands() {
    local required_commands=(
        "rsync"
        "mkfs.vfat"
        "mkfs.ext4"
        "parted"
        "sfdisk"
        "blkid"
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
if ! grep -q "$SRC_PART2 / " /proc/mounts; then
    echo "Error: $SRC_PART2 is not mounted as root! Aborting for safety."
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
            echo "Error during incremental backup!"
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

echo "You can now safely remove the destination drive."
exit 0