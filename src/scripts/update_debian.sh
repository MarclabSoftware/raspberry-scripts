#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

#==============================================================================
# Configuration
#==============================================================================
readonly BACKUP_DIR="/home/labo/backups"
BACKUP_FILE="${BACKUP_DIR}/config-backup-$(date +%Y%m%d_%H%M%S).tar.gz"
readonly BACKUP_FILE
readonly DOCKER_CONTAINERS=("node-red")
readonly DOCKER_BASE_DIR="/home/labo/docker"

#==============================================================================
# Utility Functions
#==============================================================================
log_info() {
    echo -e "\n[INFO] $1"
}

log_error() {
    echo -e "\n[ERROR] $1" >&2
}

log_warning() {
    echo -e "\n[WARNING] $1" >&2
}

show_disk_usage() {
    log_info "Disk usage:"
    df -h /
}

check_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_dependencies() {
    local -r deps=("apt" "docker" "tar" "rpi-eeprom-update")
    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" >/dev/null 2>&1; then
            log_error "Required dependency '${dep}' is not installed"
            exit 1
        fi
    done
}

#==============================================================================
# Backup Functions
#==============================================================================
create_backup() {
    log_info "Creating system backup..."
    mkdir -p "${BACKUP_DIR}"

    tar -czf "${BACKUP_FILE}" \
        /boot/firmware/config.txt \
        /boot/firmware/cmdline.txt \
        /etc/ssh/sshd_config \
        /etc/ssh/sshd_config.d/* \
        /home/labo/.ssh \
        /root/.ssh \
        /etc/systemd/journald.conf.d/labo* \
        /etc/systemd/resolved.conf.d/labo* \
        /etc/systemd/timesyncd.conf.d/labo* \
        /etc/systemd/network/end0* \
        /etc/systemd/network/eth0* \
        /etc/systemd/system/labo* \
        /etc/default/rpi-eeprom-update \
        /etc/sysctl.d/99-maxperfwiz.conf \
        /etc/sysctl.d/labo-network.conf \
        /etc/udev/rules.d/labo* \
        /etc/udev/rules.d/66-maxperfwiz.rules \
        /home/labo/.nanorc \
        /root/.nanorc \
        || log_warning "Some files could not be backed up"

    chmod 600 "${BACKUP_FILE}"
    log_info "Backup created at ${BACKUP_FILE}"
}

#==============================================================================
# System Update Functions
#==============================================================================
update_system() {
    log_info "Updating package lists..."
    apt update || {
        log_error "Failed to update package lists"
        exit 1
    }

    log_info "Performing full system upgrade..."
    apt full-upgrade -y || {
        log_error "System upgrade failed"
        exit 1
    }

    log_info "Cleaning up packages..."
    apt autoclean
    apt clean
    apt autoremove -y
}

update_raspberry_eeprom() {
    log_info "Updating Raspberry Pi EEPROM..."
    if rpi-eeprom-update -a; then
        log_info "EEPROM update completed successfully"
    else
        log_warning "EEPROM update failed or not needed"
    fi
}

#==============================================================================
# Docker Management Functions
#==============================================================================
update_docker_containers() {
    log_info "Updating Docker containers..."

    for container in "${DOCKER_CONTAINERS[@]}"; do
        if docker ps | grep -q "${container}"; then
            log_info "Updating ${container}..."
            case "${container}" in
            "node-red")
                docker exec "${container}" bash -c 'cd /data && npm update && npm cache clean --force' ||
                    log_warning "Failed to update ${container} packages"
                docker container restart "${container}" ||
                    log_warning "Failed to restart ${container}"
                ;;
            esac
        else
            log_warning "Container ${container} not found or not running"
        fi
    done
}

cleanup_docker() {
    log_info "Cleaning Docker system..."

    # Remove unused Docker images
    log_info "Removing unused Docker images..."
    docker image prune -af

    # Remove stopped containers
    log_info "Removing stopped containers..."
    docker container prune -f

    # Remove unused volumes
    log_info "Removing unused volumes..."
    docker volume prune -f

    # Remove build cache
    log_info "Removing build cache..."
    docker builder prune -f

    # Docker system prune
    log_info "Docker system prune..."
    docker system prune -a -f

    # Clean specific Docker directories
    clean_docker_directories
}

clean_docker_directories() {
    log_info "Cleaning Docker directories..."

    local dirs=(
        "esphome:./build ./platformio"
        "home-assistant:./home-assistant.log ./home-assistant.log.1 ./home-assistant.log.fault"
        "mosquitto:./log/mosquitto.log"
        "npm:./data/logs/*"
        "omada:./logs/*"
        "technitium:./logs/*"
        "vaultwarden:./data/vaultwarden.log"
        "z2m:./log/*"
    )

    for dir_entry in "${dirs[@]}"; do
        IFS=':' read -r dir files <<<"${dir_entry}"
        if cd "${DOCKER_BASE_DIR}/${dir}" 2>/dev/null; then
            log_info "Cleaning ${DOCKER_BASE_DIR}/${dir}"
            # shellcheck disable=SC2086
            rm -vrf ${files}
        else
            log_warning "${DOCKER_BASE_DIR}/${dir} not found, skipping"
        fi
    done
}

#==============================================================================
# System Cleanup Functions
#==============================================================================
cleanup_system() {
    log_info "Cleaning system logs..."
    find /var/log -type f -name "*.gz" -delete
    find /var/log -type f -name "*.1" -delete
    find /var/log -type f -name "*.old" -delete
    truncate -s 0 /var/log/*.log 2>/dev/null || true
    journalctl --vacuum-time=1d

    log_info "Cleaning temporary files..."
    find /tmp -type f -mtime +10 -delete 2>/dev/null || true
    find /var/tmp -type f -mtime +10 -delete 2>/dev/null || true

    # Clean system cache
    log_info "Cleaning system cache..."
    sync
    echo 3 >/proc/sys/vm/drop_caches
}

#==============================================================================
# Main Execution
#==============================================================================
main() {
    log_info "Starting system update process..."

    # Pre-flight checks
    check_root
    check_dependencies

    # Show initial disk usage
    show_disk_usage

    # Create system backup
    create_backup

    # Update sequence
    update_system
    update_raspberry_eeprom
    update_docker_containers

    # Cleanup sequence
    cleanup_docker
    cleanup_system

    # Show final disk usage
    show_disk_usage

    log_info "System update completed successfully!"
    log_info "Backup file: ${BACKUP_FILE}"
    log_info "A system reboot is recommended to apply all updates."
}

# Execute main function
main "$@"
