#!/bin/bash

# =============================================================================
# Raspberry Pi System Backup Script
# =============================================================================
#
# Creates an exact bootable clone of a Raspberry Pi system from one SSD to another.
# Maintains all partition UUIDs and filesystem attributes for direct replacement.
#
# Requirements:
# - Two SSDs connected via USB (/dev/sda source, /dev/sdb destination)
# - Root privileges
# - Required tools: rsync, mkfs.vfat, mkfs.ext4, fsck tools
#
# Warning: This script will completely erase the destination drive!
#
# Author: LaboDJ
# Version: 1.0
# Last Updated: 2025/01/16
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
    
    while kill -0 $pid 2>/dev/null; do
        dst_used="$(df -B1 "$DST_MOUNT_ROOT" | awk 'NR==2 {print $3}')"
        progress=$((dst_used * 100 / src_size))
        echo -ne "Progress: $progress% \r"
        sleep 1
    done
    echo -ne '\n'
}


# Check if script is run as root
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root!"
    exit 1
fi

# Check devices
check_device "/dev/sda"
check_device "/dev/sdb"

# Verify source device is correct
if ! grep -q "/dev/sda2 / " /proc/mounts; then
    echo "Error: /dev/sda2 is not mounted as root! Aborting for safety."
    exit 1
fi

# Create temporary mount points
DST_MOUNT_ROOT=$(mktemp -d)

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    safe_unmount "$DST_MOUNT_ROOT/boot/firmware"
    safe_unmount "$DST_MOUNT_ROOT"
    rm -rf "$DST_MOUNT_ROOT"
}

trap cleanup EXIT

echo "Starting backup process..."
echo "WARNING: This will erase all data on /dev/sdb"
read -p "Are you sure you want to continue? (yes/no) " -r
if [[ ! $REPLY =~ ^yes$ ]]; then
    echo "Aborting."
    exit 1
fi

# 1. Create exact copy of partition table including PARTUUIDs
echo "Creating exact partition table copy..."
dd if=/dev/sda of=/dev/sdb bs=1M count=4 conv=fsync status=progress

# Wait for kernel to update partition table
sleep 2
partprobe /dev/sdb

# 2. Create filesystems with same parameters
echo "Creating filesystems..."

# Verify that all required commands are available
for cmd in mkfs.vfat mkfs.ext4 fsck.vfat blkid fuser rsync; do
    if ! command_exists "$cmd"; then
        echo "Error: Required command '$cmd' not found"
        exit 1
    fi
done

# Verify that partitions exist and are not mounted
for part in /dev/sdb1 /dev/sdb2; do
    if [ ! -b "$part" ]; then
        echo "Error: Partition $part not found. Waiting 5 seconds for device..."
        sleep 5
        if [ ! -b "$part" ]; then
            echo "Error: Partition $part still not found"
            exit 1
        fi
    fi

    if mountpoint -q "$part" || grep -q "^$part " /proc/mounts; then
        echo "Error: $part is still mounted!"
        exit 1
    fi
done

# Create FAT filesystem on first partition
echo "Creating FAT filesystem on /dev/sdb1..."
if ! mkfs.vfat /dev/sdb1; then
    echo "Error creating FAT filesystem on /dev/sdb1"
    exit 1
fi

# Create optimized ext4 filesystem on second partition
echo "Creating ext4 filesystem on /dev/sdb2..."
if ! mkfs.ext4 -F \
    -O has_journal,extent,flex_bg,metadata_csum,64bit,dir_nlink,extra_isize \
    -E lazy_itable_init=0,lazy_journal_init=0,discard \
    -b 4096 \
    -I 256 \
    -i 32768 \
    -m 0 \
    -J size=64 \
    -L rootfs \
    /dev/sdb2; then
    echo "Error creating ext4 filesystem on /dev/sdb2"
    exit 1
fi

# Verify filesystems were created correctly
echo "Verifying filesystems..."
if ! fsck.vfat -n /dev/sdb1; then
    echo "Error verifying FAT filesystem on /dev/sdb1"
    exit 1
fi

if ! e2fsck -n /dev/sdb2; then
    echo "Error verifying ext4 filesystem on /dev/sdb2"
    exit 1
fi

echo "Filesystems created successfully"

# 3. Mount destination partitions
echo "Mounting destination partitions..."
mount /dev/sdb2 "$DST_MOUNT_ROOT"
verify_mount "$DST_MOUNT_ROOT"

mkdir -p "$DST_MOUNT_ROOT/boot/firmware"
mount /dev/sdb1 "$DST_MOUNT_ROOT/boot/firmware"
verify_mount "$DST_MOUNT_ROOT/boot/firmware"

# 4. Check space and copy data using optimized rsync
echo "Checking available space..."
check_space "/" "$DST_MOUNT_ROOT"

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
    --partial \
    --partial-dir=.rsync-partial \
    --sparse \
    / "$DST_MOUNT_ROOT/" &

RSYNC_PID=$!
show_progress $RSYNC_PID
wait $RSYNC_PID

echo "Copying firmware partition..."
rsync -aHAXx --numeric-ids --info=progress2 \
    --compress \
    --compress-level=1 \
    --partial \
    --partial-dir=.rsync-partial \
    --sparse \
    /boot/firmware/ "$DST_MOUNT_ROOT/boot/firmware/"

# 5. Verify data integrity
echo "Verifying data integrity..."
if ! rsync -avn --delete / "$DST_MOUNT_ROOT/" | grep -q "^$"; then
    echo "Warning: Differences found in root filesystem!"
    exit 1
fi

if ! rsync -avn --delete /boot/firmware/ "$DST_MOUNT_ROOT/boot/firmware/" | grep -q "^$"; then
    echo "Warning: Differences found in firmware partition!"
    exit 1
fi

# 6. Sync and verify
echo "Syncing filesystems..."
sync

# 7. Unmount before final verification
echo "Unmounting destination partitions..."
safe_unmount "$DST_MOUNT_ROOT/boot/firmware"
safe_unmount "$DST_MOUNT_ROOT"

# 8. Verify PARTUUIDs
echo "Verifying PARTUUIDs..."
SRC_PARTUUID_1=$(blkid -s PARTUUID -o value /dev/sda1)
SRC_PARTUUID_2=$(blkid -s PARTUUID -o value /dev/sda2)
DST_PARTUUID_1=$(blkid -s PARTUUID -o value /dev/sdb1)
DST_PARTUUID_2=$(blkid -s PARTUUID -o value /dev/sdb2)

echo "
Source Firmware PARTUUID: $SRC_PARTUUID_1
Backup Firmware PARTUUID: $DST_PARTUUID_1
Source Root PARTUUID: $SRC_PARTUUID_2
Backup Root PARTUUID: $DST_PARTUUID_2
"

# Verify PARTUUIDs match
if [ "$SRC_PARTUUID_1" != "$DST_PARTUUID_1" ] || [ "$SRC_PARTUUID_2" != "$DST_PARTUUID_2" ]; then
    echo "WARNING: PARTUUIDs do not match! The backup might not be bootable."
    echo "Source PARTUUIDs: $SRC_PARTUUID_1, $SRC_PARTUUID_2"
    echo "Destination PARTUUIDs: $DST_PARTUUID_1, $DST_PARTUUID_2"
    exit 1
else
    echo "PARTUUIDs match successfully!"
fi

echo "
Backup completed successfully!
The backup drive is now an exact clone and can be used as a direct replacement.
"
