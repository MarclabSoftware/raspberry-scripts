#!/usr/bin/env bash

# Bash colors
RED='\033[0;31m'   # Red color
GREEN='\033[0;32m' # Green color
NC='\033[0m'       # No color

# Script related vars
SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
SCRIPT_NAME=$(basename "$(readlink -f "${0}")" .sh)
CONFIG_F="${SCRIPT_D}/${SCRIPT_NAME}.conf"

# External scripts
UTILS_F="${SCRIPT_D}/utils.sh"
RFKILL_F="${SCRIPT_D}/rfkill.sh"
JOURNAL_LIMIT_F="${SCRIPT_D}/journal_limit.sh"
SWAPPINESS_F="${SCRIPT_D}/swappiness.sh"
PACMAN_COUNTRIES_F="${SCRIPT_D}/pacman_countries.sh"
PACMAN_COLORS_F="${SCRIPT_D}/pacman_colors.sh"
PACMAN_INSTALL_PKGS_F="${SCRIPT_D}/pacman_install_pkgs.sh"
PACMAN_CLEANUP_F="${SCRIPT_D}/pacman_cleanup.sh"
RPI_EEPROM_BRANCH_F="${SCRIPT_D}/rpi_eeprom_branch.sh"
RPI_EEPROM_UPDATE_F="${SCRIPT_D}/rpi_eeprom_update.sh"
RPI_OVERCLOCK_F="${SCRIPT_D}/rpi_overclock.sh"

# Source utils
# shellcheck source=utils.sh
. "${UTILS_F}"

clear

# Safety checks
help_text="This script must be run as super user using the command: sudo ./init_script.sh \"\${USER}\""

if ! checkSU; then
    echo "${help_text}"
    exit 1
fi

if [ $# -eq 0 ]; then
    echo "No arguments provided"
    echo "${help_text}"
    exit 1
fi

if [ "${1}" = "root" ]; then
    echo "User argument must be a normal user, you provided ${1}"
    echo "${help_text}"
    exit 1
fi

if ! id "${1}" &>/dev/null; then
    echo "User ${1} doesn't exist, please check"
    echo "${help_text}"
    exit 2
fi

# Constants
HOME_USER_D=$(sudo -u "${1}" sh -c 'echo $HOME')
HOME_ROOT_D=$(sudo -u root sh -c 'echo $HOME')
HELPER_F="${HOME_USER_D}/.${SCRIPT_NAME}_progress"
SYSCTLD_D="/etc/sysctl.d"
SYSCTLD_NETWORK_CONF_F="${SYSCTLD_D}/21-${1}_network.conf"
SUDOERS_F="/etc/sudoers.d/11-${1}"
BOOT_CMDLINE_F="/boot/cmdline.txt"
NANO_CONF_F=".nanorc"
NANO_CONF_USER_F="${HOME_USER_D}/${NANO_CONF_F}"
NANO_CONF_ROOT_F="${HOME_ROOT_D}/${NANO_CONF_F}"
TRIM_RULES_F="/etc/udev/rules.d/11-trim_samsung.rules"
RESOLVED_CONFS_D="/etc/systemd/resolved.conf.d"
RESOLVED_CONF_F="${RESOLVED_CONFS_D}/resolved-${1}.conf"
RESOLV_CONF_F="/etc/resolv.conf"
STUB_RESOLV_F="/run/systemd/resolve/stub-resolv.conf"
SSH_ROOT_D="${HOME_ROOT_D}/.ssh"
SSH_USER_D="${HOME_USER_D}/.ssh"
SSH_CONF_D="/etc/ssh"
SSH_CONF_F="${SSH_CONF_D}/sshd_config"
SSH_AUTHORIZED_KEY_USER_F="${SSH_USER_D}/authorized_keys"
SSH_AUTHORIZED_KEY_ROOT_F="${SSH_ROOT_D}/authorized_keys"
SSH_KNOWN_HOSTS_USER_F="${SSH_USER_D}/known_hosts"
SSH_KNOWN_HOSTS_ROOT_F="${SSH_ROOT_D}/known_hosts"
SYSTEMD_NETWORK_D="/etc/systemd/network/"
DHCPD_CONF_F="/etc/dhcpcd.conf"
TIMESYNCD_CONFS_D="/etc/systemd/timesyncd.conf.d"
TIMESYNCD_CONF_F="${TIMESYNCD_CONFS_D}/timesyncd-${1}.conf"

# Import config file
if [ -f "${CONFIG_F}" ]; then
    echo "Config file found... importing it"
    # shellcheck source=init.conf
    . "${CONFIG_F}"
else
    echo "Config file not found... proceeding to manual config"
fi

# Create helper file if not found
if [ ! -f "${HELPER_F}" ]; then
    echo "0" | sudo -u "${1}" tee "${HELPER_F}" >/dev/null
fi

helper_f_content=$(<"${HELPER_F}")

if [[ "${helper_f_content}" == "2" ]]; then
    echo "All config already done, exiting."
    exit 3

# First pass
elif [[ "${helper_f_content}" == "0" ]]; then

    echo -e "\nFirst init pass"

    # Rfkill - block wireless devices
    if checkConfig "CONFIG_INIT_RFKILL"; then
        # shellcheck source=rfkill.sh
        . "${RFKILL_F}"
        blockRf
    fi

    # Journal - limit size
    if checkConfig "CONFIG_INIT_JOURNAL_LIMIT"; then
        # shellcheck source=journal_limit.sh
        . "${JOURNAL_LIMIT_F}"
        limitJournal
    fi

    # RAM - set swappiness
    if checkConfig "CONFIG_INIT_RAM_SWAPPINESS_CUSTOMIZE"; then
        # shellcheck source=swappiness.sh
        . "${SWAPPINESS_F}"
        setSwappiness
    fi

    # Pacman - set mirrors
    if checkConfig "CONFIG_INIT_PACMAN_SET_MIRROR_COUNTRIES"; then
        # shellcheck source=pacman_countries.sh
        . "${PACMAN_COUNTRIES_F}"
        setPacmanCountries
    fi

    # Pacman - update
    echo -e "\n\nUpdating packages"
    # FIXME: noconfirm doesn't work with packages like linux-rpi4-mainline due to incompatibilites with installed packages
    pacman -Syyuu --noconfirm
    echo "Packages updated"

    # Pacman - enable colored output
    if checkConfig "CONFIG_INIT_PACMAN_ENABLE_COLORS"; then
        # shellcheck source=pacman_colors.sh
        . "${PACMAN_COLORS_F}"
        setPacmanColors
    fi

    # Pacman - install packages
    if checkConfig "CONFIG_INIT_PACMAN_INSTALL_PACKAGES"; then
        # shellcheck source=pacman_install_pkgs.sh
        . "${PACMAN_INSTALL_PKGS_F}"
        installPacmanPackages
    fi

    # Pacman - cleanup
    if checkConfig "CONFIG_INIT_PACMAN_CLEANUP"; then
        # shellcheck source=pacman_cleanup.sh
        . "${PACMAN_CLEANUP_F}"
        pacmanCleanup
    fi

    # Rpi - EEPROM update branch
    if checkConfig "CONFIG_INIT_RPI_EEPROM_BRANCH_CHANGE"; then
        # shellcheck source=rpi_eeprom_branch.sh
        . "${RPI_EEPROM_BRANCH_F}"
        changeEepromBranch
    fi

    # Rpi - EEPROM update check
    if checkConfig "CONFIG_INIT_RPI_EEPROM_UPDATE_CHECK"; then
        # shellcheck source=rpi_eeprom_update.sh
        . "${RPI_EEPROM_UPDATE_F}"
        updateEeprom
    fi

    # Rpi - Overclock
    if checkConfig "CONFIG_INIT_RPI_OVERCLOCK_ENABLE"; then
        # shellcheck source=rpi_overclock.sh
        . "${RPI_OVERCLOCK_F}"
        goFaster
    fi

    # User - add to groups
    if checkConfig "CONFIG_USER_ADD_TO_GROUPS"; then
        if [[ -v CONFIG_USER_GROUPS_TO_ADD[@] ]]; then
            echo -e "\n\nAdding ${1} to ${CONFIG_USER_GROUPS_TO_ADD[*]} groups"
            for group in "${CONFIG_USER_GROUPS_TO_ADD[@]}"; do
                usermod -aG "${group}" "${1}"
            done
        else
            echo "CONFIG_USER_GROUPS_TO_ADD is not defined or is not an array"
            paktc
        fi
    fi

    # User - sudo without password
    if checkConfig "CONFIG_USER_SUDO_WITHOUT_PWD"; then
        echo -e "\n\nSetting sudo without password for ${1}"
        if [ ! -f "${SUDOERS_F}" ]; then
            echo "${SUDOERS_F} doesn't exist."
            echo "${1} ALL=(ALL) NOPASSWD: ALL" | tee "${SUDOERS_F}" >/dev/null
            chmod 750 "${SUDOERS_F}"
            echo "${1} can run sudo without password from the next boot."
        else
            echo "${SUDOERS_F} already exists, please check"
            paktc
        fi
    fi

    # Nano - enable syntax highlighting
    if checkConfig "CONFIG_NANO_ENABLE_SYNTAX_HIGHLIGHTING"; then
        echo -e "\n\nEnabling Nano Syntax highlighting for root and ${1}"
        if [ ! -f "${NANO_CONF_ROOT_F}" ] || ! grep -q 'include "/usr/share/nano/\*.nanorc' "${NANO_CONF_ROOT_F}"; then
            echo -e 'include "/usr/share/nano/*.nanorc"\nset linenumbers' | tee -a "${NANO_CONF_ROOT_F}" >/dev/null
        else
            echo "${NANO_CONF_ROOT_F} already configured"
            paktc
        fi
        if [ ! -f "${NANO_CONF_USER_F}" ] || ! grep -q 'include "/usr/share/nano/\*.nanorc' "${NANO_CONF_USER_F}"; then
            echo -e 'include "/usr/share/nano/*.nanorc"\nset linenumbers' | sudo -u "${1}" tee -a "${NANO_CONF_USER_F}" >/dev/null
        else
            echo "${NANO_CONF_USER_F} already configured"
            paktc
        fi
        echo -e "\nNano Syntax highlighting enabled"
    fi

    # Network - optimizations
    if checkConfig "CONFIG_NETWORK_OPTIMIZATIONS"; then
        echo -e "\n\nAdding network confs to ${SYSCTLD_NETWORK_CONF_F}"
        echo \
            "# Improve Network performance
# This sets the max OS receive buffer size for all types of connections.
net.core.rmem_max = 8388608
# This sets the max OS send buffer size for all types of connections.
net.core.wmem_max = 8388608" | tee -a "${SYSCTLD_NETWORK_CONF_F}" >/dev/null
        echo "Network optimizations done"
    fi

    # Network - enable routing
    if checkConfig "CONFIG_NETWORK_ROUTING_ENABLE"; then
        echo -e "\n\nAdding network confs to ${SYSCTLD_NETWORK_CONF_F}"
        echo "net.ipv4.ip_forward = 1" | tee -a "${SYSCTLD_NETWORK_CONF_F}" >/dev/null
        echo "Routing enabled"
    fi

    # Network - MACVLAN host <-> docker bridge
    if checkConfig "CONFIG_NETWORK_MACVLAN_SETUP"; then
        echo -e "\n\nMACVLAN host <-> docker bridge setup"
        echo \
            "[Match]
Name=${CONFIG_NETWORK_MACVLAN_PARENT}

[Network]
MACVLAN=macvlan-${1}" | tee "${SYSTEMD_NETWORK_D}/${CONFIG_NETWORK_MACVLAN_PARENT}.network" >/dev/null

        echo \
            "[NetDev]
Name=macvlan-${1}
Kind=macvlan

[MACVLAN]
Mode=bridge" | tee "${SYSTEMD_NETWORK_D}/macvlan-${1}.netdev" >/dev/null
        echo \
            "[Match]
Name=macvlan-${1}

[Route]
Destination=${CONFIG_NETWORK_MACVLAN_RANGE}

[Network]
DHCP=no
Address=${CONFIG_NETWORK_MACVLAN_STATIC_IP}/32
IPForward=yes
ConfigureWithoutCarrier=yes" | tee "${SYSTEMD_NETWORK_D}/macvlan-${1}.network" >/dev/null
        echo -e "# Custom config by ${1}\ndenyinterfaces macvlan-${1}" | tee -a "${DHCPD_CONF_F}" >/dev/null
        echo -e "[Service]\nExecStart=\nExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any" | SYSTEMD_EDITOR="tee" systemctl edit systemd-networkd-wait-online.service
        systemctl daemon-reload
        echo -e "\nMacVLAN setup done"
    fi

    # Network - IPv6 Disable
    if checkConfig "CONFIG_NETWORK_IPV6_DISABLE"; then
        echo -e "\n\nDisabling IPv6"
        cp -a "${BOOT_CMDLINE_F}" "${BOOT_CMDLINE_F}.bak"
        echo "Boot cmdline file backed up at ${BOOT_CMDLINE_F}.bak"
        sed -i 's/$/ ipv6.disable_ipv6=1/g' "${BOOT_CMDLINE_F}"
        echo \
            "# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1" | tee -a "${SYSCTLD_NETWORK_CONF_F}" >/dev/null
        echo \
            "LinkLocalAddressing=no
IPv6AcceptRA=no" | tee -a "${SYSTEMD_NETWORK_D}/${CONFIG_NETWORK_MACVLAN_PARENT}.network" >/dev/null
        echo \
            "LinkLocalAddressing=no
IPv6AcceptRA=no" | tee -a "${SYSTEMD_NETWORK_D}/macvlan-${1}.network" >/dev/null
        echo \
            "ipv4only
noipv6rs
noipv6" | tee -a "${DHCPD_CONF_F}" >/dev/null
        echo "IPv6 disabled"
    fi

    # SSD - enable trim
    if checkConfig "CONFIG_SSD_TRIM_ENABLE"; then
        echo -e "\n\nAdding fstrim conf to ${TRIM_RULES_F}"
        echo "Configured vendor: ${CONFIG_SSD_TRIM_VENDOR:-04e8} | product: ${CONFIG_SSD_TRIM_PRODUCT:-61f5}"
        echo "Please check with command lsusb if they are correct for your SSD device"
        paktc
        echo -e 'ACTION=="add|change", ATTRS{idVendor}=="'"${CONFIG_SSD_TRIM_VENDOR:-04e8}"'", ATTRS{idProduct}=="'"${CONFIG_SSD_TRIM_PRODUCT:-61f5}"'", SUBSYSTEM=="scsi_disk", ATTR{provisioning_mode}="unmap"' | tee "${TRIM_RULES_F}" >/dev/null
        udevadm control --reload-rules
        udevadm trigger
        fstrim -av
        systemctl enable --now fstrim.timer
        echo "Trim enabled"
    fi

    # SSD - FS optimizations
    if checkConfig "CONFIG_SSD_OPTIMIZATIONS"; then
        echo -e "\n\nFilesystem optimizations for SSD/MicroSD"
        cp -a /etc/fstab /etc/fstab.bak
        echo "/etc/fstab backed up to /etc/fstab.bak"
        sed -i 's/defaults/defaults,noatime/g' /etc/fstab
        echo "Filesystem optimizations done"
    fi

    # NTP - custom config
    if checkConfig "CONFIG_NTP_CUSTOMIZATION"; then
        if systemctl is-active --quiet systemd-timesyncd; then
            echo -e "\n\nTimesyncd setup"
            echo "NTP server: ${CONFIG_NTP_SERVERS:-time.cloudflare.com}"
            echo "NTP fallback server: ${CONFIG_NTP_FALLBACK_SERVERS:-pool.ntp.org}"
            mkdir -p "${TIMESYNCD_CONFS_D}"
            echo \
                "# See timesyncd.conf(5) for details.
[Time]
NTP=${CONFIG_NTP_SERVERS:-time.cloudflare.com}
FallbackNTP=${CONFIG_NTP_FALLBACK_SERVERS:-pool.ntp.org}
#RootDistanceMaxSec=5
#PollIntervalMinSec=32
#PollIntervalMaxSec=2048
#ConnectionRetrySec=30
#SaveIntervalSec=60" | tee "${TIMESYNCD_CONF_F}" >/dev/null
            systemctl restart systemd-timesyncd
            echo "Timesyncd setup done"
        else
            echo "systemd-timesyncd is not running, maybe this OS is not using it for timesync, config not applied, please check"
            paktc
        fi
    fi

    # SSH
    echo -e "\n\nAdding .ssh user folder for root and ${1}"
    mkdir -p "${SSH_ROOT_D}"
    sudo -u "${1}" mkdir -p "${SSH_USER_D}"
    chmod 700 "${SSH_ROOT_D}" "${SSH_USER_D}"
    echo ".ssh folders added"

    if checkConfig "CONFIG_SSH_KEYS_ADD"; then
        echo -e "\n\nAdding SSH keys"
        echo -e "Please insert public SSH key for ${1} and press Enter\nEG: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB8Ht8Z3j6yDWPBHQtOp/R9rjWvfMYo3MSA/K6q8D86r"
        read -r
        echo "${REPLY}" | sudo -u "${1}" tee -a "${SSH_AUTHORIZED_KEY_USER_F}" >/dev/null
        echo -e "Please insert public SSH key for root user and press Enter\nKeep blank to skip\nEG: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB8Ht8Z3j6yDWPBHQtOp/R9rjWvfMYo3MSA/K6q8D86r"
        read -r
        echo "${REPLY}" | tee -a "${SSH_AUTHORIZED_KEY_ROOT_F}" >/dev/null
        echo "SSH keys added"
    fi

    if checkConfig "CONFIG_SSH_HOSTS_ADD"; then
        echo -e "\n\nAdding SSH useful known hosts"
        ssh-keyscan "${CONFIG_SSH_HOSTS[@]}" | tee "${SSH_KNOWN_HOSTS_ROOT_F}" >/dev/null
        mkdir -p "${SSH_USER_D}"
        cp "${SSH_KNOWN_HOSTS_ROOT_F}" "${SSH_KNOWN_HOSTS_USER_F}"
        chown "${1}:${1}" "${SSH_KNOWN_HOSTS_USER_F}"
        chmod 600 "${SSH_AUTHORIZED_KEY_ROOT_F}" "${SSH_AUTHORIZED_KEY_USER_F}" "${SSH_KNOWN_HOSTS_ROOT_F}" "${SSH_KNOWN_HOSTS_USER_F}"
        echo "SSH useful known hosts added"
    fi

    if checkConfig "CONFIG_SSH_HARDENING"; then
        echo -e "\n\nHardening SSH\nhttps://www.ssh-audit.com/hardening_guides.html for details"
        rm -rf "${SSH_CONF_D}"/ssh_host_*
        ssh-keygen -t rsa -b 4096 -f "${SSH_CONF_D}/ssh_host_rsa_key" -N ""
        ssh-keygen -t ed25519 -f "${SSH_CONF_D}/ssh_host_ed25519_key" -N ""
        awk '$5 >= 3071' "${SSH_CONF_D}/moduli" >"${SSH_CONF_D}/moduli.safe"
        mv "${SSH_CONF_D}/moduli.safe" "${SSH_CONF_D}/moduli"
        mv "${SSH_CONF_F}" "${SSH_CONF_F}.bak"
        echo "${SSH_CONF_F} backed up to ${SSH_CONF_F}.bak"
        #TODO
        echo -e "\n\nPlease paste and save the new sshd_config"
        paktc
        nano "${SSH_CONF_F}"
        echo -e "\n\nPlease test the new sshd_config before rebooting\nIf the command sudo sshd -t has no output the config is ok, otherway check it"
    fi

    # Services - bluetooth
    if checkConfig "CONFIG_SRV_BT_ENABLE"; then
        echo -e "\n\nEnabling and starting Bluetooth service"
        systemctl enable --now bluetooth
        echo -e "\nBluetooth service enabled & started"
    fi

    # Services - docker
    if checkConfig "CONFIG_SRV_DOCKER_ENABLE"; then
        echo -e "\n\nEnabling Docker service"
        systemctl enable docker.service #  FIXME: Failed to enable unit: File docker.service: Is a directory
        echo -e "\nDocker service enabled"
    fi

    # DNS
    if checkConfig "CONFIG_DNS_CUSTOMIZATION"; then
        echo -e "\n\nAdding DNS systemd-resolved configs"
        mkdir -p "${RESOLVED_CONFS_D}"
        if [ ! -f "${RESOLVED_CONF_F}" ]; then
            echo \
                "# See resolved.conf(5) for details.
[Resolve]
DNS=${CONFIG_DNS_SRVS}
FallbackDNS=${CONFIG_DNS_FALLBACK_SRVS}
#Domains=
DNSSEC=${CONFIG_DNS_DNSSEC}
#DNSOverTLS=no
#MulticastDNS=yes
#LLMNR=yes
#Cache=yes
#CacheFromLocalhost=no
DNSStubListener=no
#DNSStubListenerExtra=
#ReadEtcHosts=yes
#ResolveUnicastSingleLabel=no" | tee "${RESOLVED_CONF_F}"SSH_CONF_D >/dev/null
            echo "DNS systemd-resolved configs added"
        else
            echo "${RESOLVED_CONF_F} already exists, please check"
            paktc
        fi
    fi
    if checkConfig "CONFIG_DNS_UPLINK_MODE"; then
        echo -e "\n\nSetting systemd-resolved in uplink mode"
        mv -f "${RESOLV_CONF_F}" "${RESOLV_CONF_F}.bak"
        echo "${RESOLV_CONF_F} backed up to ${RESOLV_CONF_F}.bak"
        ln -s "${STUB_RESOLV_F}" "${RESOLV_CONF_F}"
        echo -e "\nsystemd-resolved in now configured in uplink mode"
        systemctl restart systemd-resolved
    fi

    # Pass 1 done
    echo "1" | sudo -u "${1}" tee "${HELPER_F}"
    echo -e "\n\nFirst part of the config done"
    echo "Please check sshd config using 'sudo sshd -t' command and fix any problem before rebooting"
    echo "If the command sudo sshd -t has no output the config is ok"
    echo "Reboot and run this script again to finalize the configuration"
    exit 0

# Second pass
elif [[ "${helper_f_content}" == "1" ]]; then
    echo "Second init pass"

    # Docker - login
    if checkConfig "CONFIG_DOCKER_LOGIN"; then
        echo -e "\n\nDocker login"
        echo "Please prepare docker hub user and password"
        paktc
        sudo -u "${1}" docker login
    fi

    # Docker - custom bridge network
    if checkConfig "CONFIG_DOCKER_NETWORK_ADD_CUSTOM_BRIDGE"; then
        echo -e "\n\nCreating Docker custom bridge network bridge_${1}"
        sudo -u "${1}" docker network create "bridge_${1}"
        echo "Docker custom bridge network created"
    fi

    # Docker - add MACVLAN network
    if checkConfig "CONFIG_DOCKER_NETWORK_ADD_MACVLAN"; then
        echo -e "\n\nCreating Docker custom MACVLAN network macvlan_${1}"
        sudo -u "${1}" docker network create "bridge_${1}"
        sudo -u "${1}" docker network create -d macvlan \
            --subnet="${CONFIG_NETWORK_MACVLAN_SUBNET}" \
            --ip-range="${CONFIG_NETWORK_MACVLAN_RANGE}" \
            --gateway="${CONFIG_NETWORK_MACVLAN_GATEWAY}" \
            -o parent="${CONFIG_NETWORK_MACVLAN_PARENT}" \
            --aux-address="macvlan_bridge=${CONFIG_NETWORK_MACVLAN_STATIC_IP}" \
            "macvlan_${1}"
        echo "Docker custom MACVLAN network created"
    fi

    # Backup - restore
    if checkConfig "CONFIG_BACKUP_RESTORE"; then
        echo -e "\n\nRestoring backup"
        if [ ! -f "${CONFIG_BACKUP_FILE_PATH}" ]; then
            echo -e "\nCannot find ${CONFIG_BACKUP_FILE_PATH}, please check"
            paktc
        else
            tar --same-owner -xf "${CONFIG_BACKUP_FILE_PATH}" -C /
        fi
    fi

    if checkConfig "CONFIG_DOCKER_COMPOSE_START"; then
        echo -e "\n\nStarting docker compose"
        if [ -f "${CONFIG_DOCKER_COMPOSE_FILE_PATH}" ]; then
            sudo -u "${1}" docker compose -f "${CONFIG_DOCKER_COMPOSE_FILE_PATH}" up -d
            echo -e "\nServices in ${CONFIG_DOCKER_COMPOSE_FILE_PATH} compose file should be up and running"
        else
            echo "Cannot find ${CONFIG_DOCKER_COMPOSE_FILE_PATH} compose file, please check"
            paktc
        fi
    fi

    echo "2" | sudo -u "${1}" tee "${HELPER_F}"
    echo -e "\n\nSecond part of the config done"
    exit 0
fi

exit 0
