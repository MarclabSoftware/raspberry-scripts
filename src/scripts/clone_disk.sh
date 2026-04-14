#!/usr/bin/env bash

###############################################################################
# Guided System Clone Script (RPi & x86) v2.4
#
# Creates a bootable file-level clone of the running Linux system to an external
# drive for supported layouts.
#
# Key Features:
# - Auto-Detection: Identifies source disk, boot mount, and partition table type.
# - Fail-Fast Safety: Aborts on unsupported layouts instead of guessing.
# - Boot Safety: Generates fresh UUIDs and patches /etc/fstab, cmdline, and loaders.
# - Optimization: SSD-friendly formatting and smart rsync exclusions (caches, tmp).
# - Robustness: Strict error handling, safe cleanup traps, and LVM/LUKS guards.
#
# Usage: sudo ./clone_disk.sh
#
# Requirements: rsync, parted, mkfs.*, blkid, lsblk, findmnt
# Supported: ext4 root + single vfat boot mount + RPi firmware or systemd-boot
# Author: LaboDJ | Last Updated: 2026/04/14
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
declare -ra REQUIRED_COMMANDS=(rsync parted mkfs.vfat mkfs.ext4 blkid lsblk grep awk sed dd stat truncate udevadm partprobe findmnt mountpoint fstrim wipefs numfmt fsck fsck.fat mkswap)

# Known boot mount points to validate against fstab (order = priority)
declare -ra BOOT_MOUNT_CANDIDATES=(/boot/firmware /boot/efi /efi /boot)

# Supported topology:
# - Plain partition root on ext4
# - Exactly one dedicated boot mount among BOOT_MOUNT_CANDIDATES
# - Boot filesystem on vfat
# - Bootloader: Raspberry Pi firmware (cmdline.txt) or systemd-boot
declare -r BOOT_PARTITION_SIZE_MIB=1024
declare -r BOOT_PARTITION_HEADROOM_MIB=64

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

# Colors (enabled only on TTY unless NO_COLOR is set)
declare GREEN=""
declare YELLOW=""
declare RED=""
declare NC=""

# Global Variables
declare DST_MOUNT_ROOT=""
declare SRC_DEVICE=""
declare DST_DEVICE=""
declare SRC_TABLE_TYPE=""
declare SRC_ROOT_FS_TYPE=""
declare SRC_BOOT_FS_TYPE=""
declare SOURCE_BOOTLOADER=""
declare DST_PART1=""
declare DST_PART2=""
declare BOOT_MOUNT=""
declare -a AVAILABLE_DISKS=()
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

# Initialize log colors only when stderr is interactive
setup_colors() {
    if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        RED='\033[0;31m'
        NC='\033[0m'
    else
        GREEN=""
        YELLOW=""
        RED=""
        NC=""
    fi
}

# Log an error message and terminate the script immediately.
# @param $* The error message to log
die() {
    log "ERROR" "$*"
    exit 1
}

# Verify script is run as root
check_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "This script must be run as root."
}

# Check for all required dependencies
check_dependencies() {
    local missing=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required commands: ${missing[*]}"
}

# Detect partition table type of a disk (mbr or gpt)
# Args: $1 - disk device (e.g., /dev/sda)
# Returns: "gpt", "mbr", or "unknown"
detect_partition_table() {
    local disk=$1
    local label
    label=$(lsblk -dn -o PTTYPE "$disk" 2>/dev/null | awk 'NF { print $1; exit }' || true)
    case "$label" in
        gpt) echo "gpt"; return 0 ;;
        dos|msdos) echo "mbr"; return 0 ;;
    esac
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

# Get parent disk device for a partition/device
# Args: $1 - partition path
# Returns: parent disk path (e.g. /dev/sda)
get_parent_disk() {
    local device=$1
    local parent
    parent=$(lsblk -no PKNAME "$device" 2>/dev/null | awk 'NF { print $1; exit }' || true)
    [[ -n "$parent" ]] || return 1
    printf '/dev/%s\n' "$parent"
}

# Check whether a string exists in an array
# Args: $1 - needle, $@ - haystack
contains_value() {
    local needle=$1
    shift
    local value
    for value in "$@"; do
        [[ "$value" == "$needle" ]] && return 0
    done
    return 1
}

# Discover disks that can be selected as destinations
discover_available_disks() {
    mapfile -t AVAILABLE_DISKS < <(lsblk -dn -p -o NAME,TYPE | awk '$2 == "disk" { print $1 }')
    [[ ${#AVAILABLE_DISKS[@]} -gt 0 ]] || die "No block disks were detected by lsblk."
    [[ ${#AVAILABLE_DISKS[@]} -ge 2 ]] || die "At least two whole-disk devices are required (source + destination)."
}

# Print a compact human-readable disk description
# Args: $1 - disk path
describe_disk() {
    local disk=$1
    local size model serial transport removable

    size=$(lsblk -dn -o SIZE "$disk" 2>/dev/null | awk '{$1=$1; print}')
    model=$(lsblk -dn -o MODEL "$disk" 2>/dev/null | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    serial=$(lsblk -dn -o SERIAL "$disk" 2>/dev/null | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    transport=$(lsblk -dn -o TRAN "$disk" 2>/dev/null | awk '{$1=$1; print}')
    removable=$(lsblk -dn -o RM "$disk" 2>/dev/null | awk '{$1=$1; print}')

    [[ -n "$size" ]] || size="-"
    [[ -n "$model" ]] || model="-"
    [[ -n "$serial" ]] || serial="-"
    [[ -n "$transport" ]] || transport="-"
    [[ -n "$removable" ]] || removable="-"

    printf 'size=%s | model=%s | serial=%s | tran=%s | rm=%s' \
        "$size" "$model" "$serial" "$transport" "$removable"
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

# Read boot-like mount points defined in /etc/fstab
# Returns one path per line
get_fstab_boot_mounts() {
    awk '
        $0 !~ /^[[:space:]]*#/ && NF >= 2 {
            mount_point = $2
            if (length(mount_point) > 1) sub(/\/$/, "", mount_point)
            if (mount_point == "/boot/firmware" || mount_point == "/boot/efi" || mount_point == "/efi" || mount_point == "/boot") {
                print mount_point
            }
        }
    ' /etc/fstab
}

# Detect the single supported boot mount from fstab and validate that it is mounted.
detect_supported_boot_mount() {
    local -a boot_mounts=()
    mapfile -t boot_mounts < <(get_fstab_boot_mounts)

    if [[ ${#boot_mounts[@]} -eq 0 ]]; then
        die "Unsupported layout: no dedicated boot mount found in /etc/fstab. This script requires exactly one of: ${BOOT_MOUNT_CANDIDATES[*]}"
    fi

    if [[ ${#boot_mounts[@]} -gt 1 ]]; then
        die "Unsupported layout: multiple boot mount points detected in /etc/fstab (${boot_mounts[*]}). This script supports exactly one dedicated boot mount."
    fi

    BOOT_MOUNT="${boot_mounts[0]}"
    mountpoint -q "$BOOT_MOUNT" || die "Boot mount $BOOT_MOUNT is defined in /etc/fstab but is not currently mounted."
}

# Detect the supported source topology and fail fast on unsupported systems.
validate_supported_source_layout() {
    local root_part root_disk boot_source

    root_part=$(findmnt -n -o SOURCE /)
    SRC_ROOT_FS_TYPE=$(findmnt -n -o FSTYPE /)

    if [[ "$root_part" == /dev/mapper/* ]]; then
        die "Unsupported layout: detected device-mapper root ($root_part). LVM/LUKS cloning is out of scope for this script."
    fi

    root_disk=$(get_parent_disk "$root_part") || die "Could not resolve the parent disk for root source $root_part."
    SRC_DEVICE="$root_disk"

    [[ -b "$SRC_DEVICE" ]] || die "Detected source device $SRC_DEVICE is not a valid block disk."
    [[ "$SRC_ROOT_FS_TYPE" == "ext4" ]] || die "Unsupported root filesystem: $SRC_ROOT_FS_TYPE. This script currently supports ext4 root only."

    SRC_TABLE_TYPE=$(detect_partition_table "$SRC_DEVICE")
    [[ "$SRC_TABLE_TYPE" != "unknown" ]] || die "Could not detect the partition table type for source disk $SRC_DEVICE."

    detect_supported_boot_mount
    SRC_BOOT_FS_TYPE=$(findmnt -n -o FSTYPE "$BOOT_MOUNT")
    [[ "$SRC_BOOT_FS_TYPE" == "vfat" ]] || die "Unsupported boot filesystem on $BOOT_MOUNT: $SRC_BOOT_FS_TYPE. This script currently supports vfat boot partitions only."

    boot_source=$(findmnt -n -o SOURCE "$BOOT_MOUNT")
    if [[ "$boot_source" == /dev/mapper/* ]]; then
        die "Unsupported layout: detected device-mapper boot partition ($boot_source)."
    fi

    if [[ -f "$BOOT_MOUNT/cmdline.txt" ]]; then
        SOURCE_BOOTLOADER="rpi-firmware"
    elif [[ -d "$BOOT_MOUNT/loader/entries" ]] || [[ -d "/boot/loader/entries" ]]; then
        SOURCE_BOOTLOADER="systemd-boot"
    elif [[ -f "/boot/grub/grub.cfg" ]] || [[ -f "/boot/grub2/grub.cfg" ]] || [[ -f "$BOOT_MOUNT/grub/grub.cfg" ]] || [[ -f "$BOOT_MOUNT/grub2/grub.cfg" ]]; then
        SOURCE_BOOTLOADER="grub"
    else
        SOURCE_BOOTLOADER="unknown"
    fi

    case "$SOURCE_BOOTLOADER" in
        rpi-firmware|systemd-boot) ;;
        grub)
            die "Unsupported bootloader: GRUB detected. This script does not regenerate GRUB config safely after UUID changes."
            ;;
        *)
            die "Unsupported bootloader layout under $BOOT_MOUNT. Supported bootloaders: Raspberry Pi firmware or systemd-boot."
            ;;
    esac
}

# Ensure the destination disk is not mounted anywhere before formatting or fsck.
# Args: $1 - disk path
ensure_disk_unmounted() {
    local disk=$1
    local mount_path

    while read -r mount_path; do
        [[ -n "$mount_path" ]] || continue
        log "WARN" "Unmounting existing destination mount: $mount_path"
        umount "$mount_path" || die "Failed to unmount destination path $mount_path"
    done < <(lsblk -nr -o MOUNTPOINT "$disk" | awk 'NF')
}

# Ensure the destination disk selection points to a real whole disk.
# Args: $1 - disk path
validate_destination_disk() {
    local disk=$1
    if [[ ! -b "$disk" ]]; then
        log "WARN" "Destination $disk is not a block device."
        return 1
    fi

    if [[ "$(lsblk -dn -o TYPE "$disk" 2>/dev/null | awk 'NF { print $1; exit }')" != "disk" ]]; then
        log "WARN" "Destination $disk is not a whole disk device."
        return 1
    fi

    return 0
}

# Check that destination partitions are suitable for incremental sync
validate_incremental_target_layout() {
    local part1_fs part2_fs

    [[ -b "$DST_PART1" && -b "$DST_PART2" ]] || die "Incremental update requires existing destination partitions $DST_PART1 and $DST_PART2."

    part1_fs=$(blkid -s TYPE -o value "$DST_PART1" 2>/dev/null || true)
    part2_fs=$(blkid -s TYPE -o value "$DST_PART2" 2>/dev/null || true)

    [[ "$part1_fs" == "vfat" ]] || die "Incremental update requires $DST_PART1 to be vfat, found: ${part1_fs:-unknown}."
    [[ "$part2_fs" == "ext4" ]] || die "Incremental update requires $DST_PART2 to be ext4, found: ${part2_fs:-unknown}."
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
    local entries_found=false
    for entry in "$entries_dir"/*.conf; do
        entries_found=true
        log "INFO" "Patching systemd-boot entry: $(basename "$entry")"
        if grep -q "root=" "$entry"; then
            sed -E -i "s/root=[^ ]+/root=PARTUUID=$new_partuuid/g" "$entry"
        fi
    done
    [[ "$entries_found" == true ]]
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
    local failures=0
    shopt -s nullglob
    trap 'shopt -u nullglob' RETURN
    for entry in "$entries_dir"/*.conf; do
        found=true
        if grep -v "^[[:space:]]*#" "$entry" | grep -qF -e "$partuuid" -e "$uuid"; then
            log "INFO" "[PASS] systemd-boot entry${label} $(basename "$entry") updated"
        else
            log "ERROR" "[FAIL] systemd-boot entry${label} $(basename "$entry") NOT updated!"
            ((failures++))
        fi
    done
    [[ "$found" == true ]] || return 1
    ((failures == 0))
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

    local total_src_used=$src_root_used
    if [[ "$(findmnt -n -o SOURCE "$src_root")" != "$(findmnt -n -o SOURCE "$src_boot")" ]]; then
        total_src_used=$((src_root_used + src_boot_used))
    fi
    
    # Get destination size in bytes
    local dst_size
    dst_size=$(lsblk -b -n -o SIZE -d "$dst_disk")
    
    # Add Safety Margin: 2GB + 5% of source data
    # This accounts for filesystem overhead (inodes, journal) which grows with disk size/file count
    local base_margin=$((2 * 1024 * 1024 * 1024))
    local percent_margin=$((total_src_used * 5 / 100))
    local required_size=$((total_src_used + base_margin + percent_margin))
    local boot_partition_bytes=$((BOOT_PARTITION_SIZE_MIB * 1024 * 1024))
    local boot_headroom_bytes=$((BOOT_PARTITION_HEADROOM_MIB * 1024 * 1024))

    if (( src_boot_used + boot_headroom_bytes > boot_partition_bytes )); then
        die "Boot data on $src_boot uses $(numfmt --to=iec-i --suffix=B "$src_boot_used"), which is too large for the fixed ${BOOT_PARTITION_SIZE_MIB}MiB destination boot partition."
    fi
    
    if [[ "$dst_size" -lt "$required_size" ]]; then
        log "ERROR" "Destination disk is too small."
        log "ERROR" "Required (source data + margin): $(numfmt --to=iec-i --suffix=B "$required_size")"
        log "ERROR" "Destination available:           $(numfmt --to=iec-i --suffix=B "$dst_size")"
        die "Aborting: destination disk too small to hold source data."
    else
        log "INFO" "Space check passed."
        log "INFO" "Required (source data + margin): $(numfmt --to=iec-i --suffix=B "$required_size")"
        log "INFO" "Destination available:           $(numfmt --to=iec-i --suffix=B "$dst_size")"
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
                local trim_out
                trim_out=$(fstrim -v "$DST_MOUNT_ROOT" 2>&1) && log "INFO" "fstrim root: $trim_out" || true
                # Also trim the boot partition if it is still mounted.
                if [[ -n "$BOOT_MOUNT" ]] && mountpoint -q "$DST_MOUNT_ROOT$BOOT_MOUNT" 2>/dev/null; then
                    trim_out=$(fstrim -v "$DST_MOUNT_ROOT$BOOT_MOUNT" 2>&1) && log "INFO" "fstrim boot: $trim_out" || true
                fi
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
# Configures signal traps for robust error handling and cleanup on all exit paths.
setup_signal_handlers() {
    trap 'handle_error $LINENO' ERR
    trap 'log "INFO" "Received SIGINT. Cleaning up..."; exit 130' INT
    trap 'log "INFO" "Received SIGTERM. Cleaning up..."; exit 143' TERM
    trap 'cleanup' EXIT
}

###################
# Core Logic
###################

# Interactive disk selection menu
select_disks() {
    echo "=== Disk Selection ==="

    log "INFO" "Detecting source topology..."
    validate_supported_source_layout
    discover_available_disks

    log "INFO" "Detected Source: $SRC_DEVICE"
    log "INFO" "Source Root FS: $SRC_ROOT_FS_TYPE | Boot Mount: $BOOT_MOUNT ($SRC_BOOT_FS_TYPE) | Bootloader: $SOURCE_BOOTLOADER | Partition Table: $SRC_TABLE_TYPE"
    log "INFO" "Available disks:"

    local idx disk marker
    for idx in "${!AVAILABLE_DISKS[@]}"; do
        disk="${AVAILABLE_DISKS[$idx]}"
        marker=""
        [[ "$disk" == "$SRC_DEVICE" ]] && marker=" [SOURCE]"
        printf '  [%d] %s %s%s\n' "$((idx + 1))" "$disk" "$(describe_disk "$disk")" "$marker"
    done

    # Select Destination
    while true; do
        local selection=""
        printf '\nSelect DESTINATION disk by number or exact path (e.g. 2 or /dev/sdb): '
        read -r selection

        if [[ "$selection" =~ ^[0-9]+$ ]]; then
            local choice_index=$((selection - 1))
            if (( choice_index < 0 || choice_index >= ${#AVAILABLE_DISKS[@]} )); then
                log "WARN" "Invalid selection index: $selection"
                continue
            fi
            DST_DEVICE="${AVAILABLE_DISKS[$choice_index]}"
        else
            DST_DEVICE="$selection"
        fi

        validate_destination_disk "$DST_DEVICE" || continue
        contains_value "$DST_DEVICE" "${AVAILABLE_DISKS[@]}" || {
            log "WARN" "Device $DST_DEVICE is not in the current lsblk disk list."
            continue
        }

        if [[ "$SRC_DEVICE" == "$DST_DEVICE" ]]; then
            log "WARN" "Source and destination cannot be the same device."
            continue
        fi

        ensure_disk_unmounted "$DST_DEVICE"
        break
    done

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
    boot_mount_point="$BOOT_MOUNT"
    check_space "/" "$boot_mount_point" "$DST_DEVICE"

    # 1. Wipe and Partition
    # We recreate the partition table to match the source type (MBR or GPT).
    ensure_disk_unmounted "$DST_DEVICE"
    log "INFO" "Wiping existing signatures..."
    wipefs -a "$DST_DEVICE" >/dev/null 2>&1 || true

    log "INFO" "Creating partition table..."
    if [[ "$SRC_TABLE_TYPE" == "gpt" ]]; then
        # x86/UEFI: GPT with 1024 MiB ESP + root. All operations in one invocation
        # to avoid leaving the disk in a partially-partitioned state between calls.
        parted -s -a optimal "$DST_DEVICE" \
            mklabel gpt \
            mkpart "EFI" fat32 1MiB "$((BOOT_PARTITION_SIZE_MIB + 1))"MiB \
            set 1 esp on \
            mkpart "Root" ext4 "$((BOOT_PARTITION_SIZE_MIB + 1))"MiB 100%
    else
        # RPi/Legacy: MBR (msdos) with 1024 MiB FAT32 boot + root.
        parted -s -a optimal "$DST_DEVICE" \
            mklabel msdos \
            mkpart primary fat32 1MiB "$((BOOT_PARTITION_SIZE_MIB + 1))"MiB \
            mkpart primary ext4 "$((BOOT_PARTITION_SIZE_MIB + 1))"MiB 100%
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
            die "Timed out waiting for partition devices $DST_PART1 / $DST_PART2 to appear."
        fi
        sleep 1
    done

    # 2. Format
    log "INFO" "Formatting partitions..."
    mkfs.vfat -F 32 -n "BOOT" "$DST_PART1" >/dev/null 2>&1
    mkfs.ext4 -q -F "${EXT4_OPTIONS[@]}" -i "$INODE_RATIO" -L "rootfs" "$DST_PART2"

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
    validate_incremental_target_layout
    ensure_disk_unmounted "$DST_DEVICE"
    
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
        # Use the filesystem-appropriate checker: fsck.fat for FAT32 (-a = auto-repair)
        # does not accept the -y flag, which is ext4/e2fsck-specific.
        local fs_type
        fs_type=$(blkid -s TYPE -o value "$part" 2>/dev/null || true)
        if [[ "$fs_type" == "vfat" ]]; then
            fsck.fat -a "$part" || log "WARN" "fsck.fat on $part returned non-zero (code $?), proceeding..."
        else
            fsck -y "$part" || log "WARN" "fsck on $part returned non-zero (code $?), proceeding..."
        fi
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

    # BOOT_MOUNT is set by mount_destination(); declare local copies to avoid
    # leaking into the global scope.
    local SRC_BOOT="$BOOT_MOUNT/"
    local DST_BOOT="$DST_MOUNT_ROOT$BOOT_MOUNT/"

    # Sync Boot Partition.
    # FAT32-specific flags:
    # --no-perms/--no-owner/--no-group: FAT32 has no Unix permission model.
    # --copy-links: FAT32 has no symlink support; copy the target file instead.
    # --modify-window=2: FAT32 timestamps have 2-second resolution.
    local boot_rsync_exit=0
    rsync -rt --no-perms --no-owner --no-group --copy-links --info=progress2 --delete --modify-window=2 \
        "$SRC_BOOT" "$DST_BOOT" || boot_rsync_exit=$?

    if [[ $boot_rsync_exit -eq 0 ]]; then
        log "INFO" "Boot sync completed successfully."
    elif [[ $boot_rsync_exit -eq 24 ]]; then
        log "WARN" "Rsync reported vanished files during boot sync (code 24). Normal on a live system."
    else
        die "Boot rsync failed with error code $boot_rsync_exit."
    fi
}

# Update destination configuration files (fstab, cmdline.txt)
# This ensures the cloned system boots by using the correct NEW UUIDs.
update_destination_config() {
    log "INFO" "Updating destination configuration (fstab/cmdline)..."

    # Retrieve NEW UUIDs/PARTUUIDs from the freshly formatted destination partitions.
    local new_root_uuid new_boot_uuid new_root_partuuid new_boot_partuuid
    new_root_uuid=$(get_uuid "$DST_PART2")
    new_boot_uuid=$(get_uuid "$DST_PART1")
    new_root_partuuid=$(get_partuuid "$DST_PART2")
    new_boot_partuuid=$(get_partuuid "$DST_PART1")

    log "INFO" "New root: UUID=$new_root_uuid  PARTUUID=$new_root_partuuid"
    log "INFO" "New boot: UUID=$new_boot_uuid  PARTUUID=$new_boot_partuuid"

    local dst_fstab="$DST_MOUNT_ROOT/etc/fstab"
    # cmdline.txt path is boot-mount-relative; works for both /boot and /boot/firmware.
    local dst_cmdline="$DST_MOUNT_ROOT$BOOT_MOUNT/cmdline.txt"

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
        
        log "INFO" "Allocating $(numfmt --to=iec-i --suffix=B "$swap_size") for swapfile..."
        # fallocate is near-instant on ext4 and produces a proper non-sparse file
        # suitable for use as swap (supported since kernel 4.0).
        # Fall back to dd only if fallocate is unavailable or unsupported by the fs.
        local alloc_ok=false
        if command -v fallocate >/dev/null 2>&1; then
            if fallocate -l "$swap_size" "$DST_MOUNT_ROOT$swapfile"; then
                alloc_ok=true
            else
                log "WARN" "fallocate failed (filesystem may not support it). Falling back to dd..."
                rm -f "$DST_MOUNT_ROOT$swapfile"
            fi
        fi
        if [[ "$alloc_ok" == false ]]; then
            local swap_mb=$(( (swap_size + 1048575) / 1048576 ))
            dd if=/dev/zero of="$DST_MOUNT_ROOT$swapfile" bs=1M count="$swap_mb" && alloc_ok=true || true
            [[ "$alloc_ok" == true ]] && truncate -s "$swap_size" "$DST_MOUNT_ROOT$swapfile"
        fi

        if [[ "$alloc_ok" == true ]]; then
            chmod 600 "$DST_MOUNT_ROOT$swapfile"
            mkswap "$DST_MOUNT_ROOT$swapfile" >/dev/null
            log "INFO" "Swapfile recreated successfully ($(numfmt --to=iec-i --suffix=B "$swap_size"))."
        else
            log "WARN" "Failed to allocate swapfile. Skipping."
        fi
    fi
}

# Verify the backup configuration
verify_backup() {
    log "INFO" "=== Verifying Backup Configuration ==="

    local root_uuid root_partuuid
    local boot_uuid boot_partuuid
    root_uuid=$(get_uuid "$DST_PART2")
    root_partuuid=$(get_partuuid "$DST_PART2")
    boot_uuid=$(get_uuid "$DST_PART1")
    boot_partuuid=$(get_partuuid "$DST_PART1")

    local failures=0
    local expected_root_ref expected_boot_ref
    if [[ "$SRC_TABLE_TYPE" == "gpt" ]]; then
        expected_root_ref="UUID=$root_uuid"
        expected_boot_ref="UUID=$boot_uuid"
    else
        expected_root_ref="PARTUUID=$root_partuuid"
        expected_boot_ref="PARTUUID=$boot_partuuid"
    fi

    [[ -f "$DST_MOUNT_ROOT/etc/fstab" ]] || die "Verification failed: destination fstab is missing."

    if awk -v expected="$expected_root_ref" '$0 !~ /^[[:space:]]*#/ && $2 == "/" { found=1; if ($1 == expected) ok=1 } END { exit ! (found && ok) }' "$DST_MOUNT_ROOT/etc/fstab"; then
        log "INFO" "[PASS] fstab root entry updated to $expected_root_ref."
    else
        log "ERROR" "[FAIL] fstab root entry was not updated to $expected_root_ref."
        ((failures++))
    fi

    if awk -v expected="$expected_boot_ref" -v boot_mount="$BOOT_MOUNT" '
        $0 !~ /^[[:space:]]*#/ && NF >= 2 {
            mount_point = $2
            if (length(mount_point) > 1) sub(/\/$/, "", mount_point)
            if (mount_point == boot_mount) {
                found=1
                if ($1 == expected) ok=1
            }
        }
        END { exit ! (found && ok) }
    ' "$DST_MOUNT_ROOT/etc/fstab"; then
        log "INFO" "[PASS] fstab boot entry updated to $expected_boot_ref."
    else
        log "ERROR" "[FAIL] fstab boot entry was not updated to $expected_boot_ref."
        ((failures++))
    fi

    # Check cmdline.txt (RPi); path is boot-mount-relative, same as update_destination_config.
    local dst_cmdline="$DST_MOUNT_ROOT$BOOT_MOUNT/cmdline.txt"
    if [[ -f "$dst_cmdline" ]]; then
        if grep -qF "$root_partuuid" "$dst_cmdline"; then
            log "INFO" "[PASS] cmdline.txt updated with new root PARTUUID."
        else
            log "ERROR" "[FAIL] cmdline.txt does not contain the new root PARTUUID."
            ((failures++))
        fi
    fi

    # Check systemd-boot entries (primary path, then fallback).
    local loader_entries_dir="$DST_MOUNT_ROOT$BOOT_MOUNT/loader/entries"
    local alt_loader_dir="$DST_MOUNT_ROOT/boot/loader/entries"
    if [[ "$SOURCE_BOOTLOADER" == "systemd-boot" ]]; then
        if _verify_loader_entries "$loader_entries_dir" "$root_uuid" "$root_partuuid" ""; then
            :
        elif _verify_loader_entries "$alt_loader_dir" "$root_uuid" "$root_partuuid" "(fallback)"; then
            :
        else
            log "ERROR" "[FAIL] systemd-boot entries were not verified successfully."
            ((failures++))
        fi
    fi

    if (( failures > 0 )); then
        die "Verification failed: $failures check(s) did not pass. The cloned system may not boot."
    fi

    log "INFO" "All verification checks passed."
}

###################
# Main Execution
###################

main() {
    setup_colors
    setup_signal_handlers
    check_root
    check_dependencies

    select_disks

    echo "=============================================="
    echo " Source:      $SRC_DEVICE ($SRC_TABLE_TYPE, root=$SRC_ROOT_FS_TYPE, boot=$BOOT_MOUNT/$SRC_BOOT_FS_TYPE)"
    echo " Bootloader:  $SOURCE_BOOTLOADER"
    echo " Destination: $DST_DEVICE ($(describe_disk "$DST_DEVICE"))"
    echo "=============================================="
    echo "WARNING: ALL DATA ON $DST_DEVICE WILL BE ERASED!"
    echo "=============================================="

    # Detect whether the destination already contains a cloneable system by
    # probing for a valid fstab on its second partition.
    local is_backup=false
    if [[ -b "$DST_PART1" ]] && [[ -b "$DST_PART2" ]]; then
        local tmp_check
        tmp_check=$(mktemp -d)
        if mount "$DST_PART2" "$tmp_check" 2>/dev/null; then
            [[ -f "$tmp_check/etc/fstab" ]] && is_backup=true
            umount "$tmp_check"
        fi
        rm -rf "$tmp_check"
    fi

    if [[ "$is_backup" == true ]]; then
        log "INFO" "Destination appears to contain an existing system/backup."
        read -p "Perform INCREMENTAL update? (y/n — 'n' triggers FULL wipe): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            perform_incremental_update
            return 0
        fi
    fi

    read -p "Perform FULL BACKUP (Wipe & Clone)? (yes/no): " -r
    if [[ $REPLY =~ ^yes$ ]]; then
        read -r -p "Type the full destination path to confirm destructive wipe ($DST_DEVICE): " confirmation
        [[ "$confirmation" == "$DST_DEVICE" ]] || die "Confirmation mismatch. Refusing to wipe $DST_DEVICE."
        perform_full_backup
    else
        log "WARN" "Aborted by user."
        return 0
    fi
}

main "$@"
