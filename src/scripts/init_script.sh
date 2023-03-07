#!/usr/bin/env bash

check_config() {
    # Return 0 as true, 1 as false, any other number as error.
    if [ $# -eq 0 ]; then
        echo "${BASH_SOURCE[$i + 1]}:${BASH_LINENO[$i]} - ${FUNCNAME[$i]}: no arguments supplied"
        return 2
    fi
    if [ "${!1}" = true ]; then
        return 0 # True
    fi
    if [ "${!1}" = false ]; then
        return 1 # False
    fi
    if [ -z ${!1+x} ] || [ "${!1}" = "ask" ]; then
        read -p "Do you want to apply init config for ${1}? Y/N: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            return 0 # True
        else
            return 1 # False
        fi
    fi
    echo "${BASH_SOURCE[$i + 1]}:${BASH_LINENO[$i]} - ${FUNCNAME[$i]}: config error for ${1}: wrong value, current value: ${!1}, possible values are true,false,ask"
    return 3
}

# Bash colors
RED='\033[0;31m'   # Red color
GREEN='\033[0;32m' # Green color
NC='\033[0m'       # No color

# Script related vars
SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
SCRIPT_NAME=$(basename "$(readlink -f "${0}")" .sh)
CONFIG_F="${SCRIPT_D}/${SCRIPT_NAME}.conf"

# Constants
HOME_USER_D="/home/${1}"
HOME_ROOT_D="/root"
SCRIPT_HELPER_F="${HOME_USER_D}/.init_script_progress"
JOURNAL_CONF_D="/etc/systemd/journald.conf.d"
SUDOERS_F="/etc/sudoers.d/11-${1}"
BOOT_CONF_F="/boot/config.txt"
BOOT_CMDLINE_F="/boot/cmdline.txt"
NANO_CONF_F=".nanorc"
NANO_CONF_USER_F="${HOME_USER_D}/${NANO_CONF_F}"
NANO_CONF_ROOT_F="${HOME_ROOT_D}/${NANO_CONF_F}"
PACMAN_CONF_F="/etc/pacman.conf"
EEPROM_UPDATE_F="/etc/default/rpi-eeprom-update"
NETWORK_SYSCTL_CONF_F="/etc/sysctl.d/21-${1}_network.conf"
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

# Safety checks
if [ ! "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "Please run as root"
    echo "This script must be run as super user using the command: sudo ./init_script.sh \"\${USER}\""
    echo -e "${RED}Exiting.${NC}"
    exit 1
fi

if [ "${1}" = "root" ]; then
    echo "User argument must be a normal user, you provided ${1}"
    echo "This script must be run as regular user using the command: sudo ./init_script.sh \"\${USER}\""
    echo -e "${RED}Exiting.${NC}"
    exit 1
fi

if [ ! -d "${HOME_USER_D}" ]; then
    echo "User ${1} doesn't exist, please check"
    echo "This script must be run as regular user with using command: sudo ./init_script.sh \"\${USER}\""
    echo -e "${RED}Exiting.${NC}"
    exit 2
fi

if [ -f "${SCRIPT_HELPER_F}" ]; then
    if [[ $(<"${SCRIPT_HELPER_F}") == "2" ]]; then
        echo "All config already done, exiting."
        exit 3
    fi
fi

# Import config file
if [ -f "${CONFIG_F}" ]; then
    echo "Config file found... importing it"
    source "${CONFIG_F}"
else
    echo "Config file not found... proceeding to manual config"
fi

# First pass
if [ ! -f "${SCRIPT_HELPER_F}" ] || [[ $(<"${SCRIPT_HELPER_F}") == "0" ]]; then
    echo "First init pass"

    # Block WLAN
    if check_config "CONFIG_INIT_BLOCK_WLAN"; then
        echo -e "\nBlocking WLAN"
        rfkill block wlan
        echo "WLAN Blocked"
    fi

    # Journal - limit size
    if check_config "CONFIG_INIT_JOURNAL_LIMIT"; then
        echo -e "\n\nLimit journal size"
        mkdir -p "${JOURNAL_CONF_D}"
        echo -e "Using SystemMaxUse=${CONFIG_INIT_JOURNAL_SYSTEM_MAX:-250M}\nSystemMaxFileSize=${CONFIG_INIT_JOURNAL_FILE_MAX:-50M}"
        echo -e "[Journal]\nSystemMaxUse=${CONFIG_INIT_JOURNAL_SYSTEM_MAX:-250M}\nSystemMaxFileSize=${CONFIG_INIT_JOURNAL_FILE_MAX:-50M}" | tee "${JOURNAL_CONF_D}/size.conf" >/dev/null
        echo "New conf file is located at ${JOURNAL_CONF_D}/size.conf"
        echo "Journal size limited"
    fi

    # Pacman - set mirrors
    if check_config "CONFIG_INIT_PACMAN_SET_MIRROR_COUNTRIES"; then
        echo -e "\n\nUpdating pacman mirrors"
        if command -v pacman-mirrors &>/dev/null; then
            echo "Using ${CONFIG_INIT_PACMAN_MIRRORS_COUNTRIES:-Global} as mirrors"
            pacman-mirrors --country "${CONFIG_INIT_PACMAN_MIRRORS_COUNTRIES:-Global}"
            echo "Pacman mirrors updated"
        else
            echo "Missing pacman-mirrors command"
            read -n 1 -s -r -p "Press any key to continue"
        fi
    fi

    # Pacman - update
    echo -e "\n\nUpdating packages"
    pacman -Syyuu --noconfirm
    echo "Packages updated"

    # Pacman - enable colored output
    if check_config "CONFIG_INIT_PACMAN_ENABLE_COLORS"; then
        echo -e "\n\nEnabling Pacman colored output"
        cp -a "${PACMAN_CONF_F}" "${PACMAN_CONF_F}.bak"
        echo "Pacman config file backed up at ${PACMAN_CONF_F}.bak"
        sed -i 's/#Color/Color\nILoveCandy/g' "${PACMAN_CONF_F}"
        echo -e "Pacman colored output enabled"
    fi

    # Pacman - install packages
    if check_config "CONFIG_INIT_PACMAN_INSTALL_PACKAGES"; then
        if [[ -v CONFIG_INIT_PACMAN_PACKAGES[@] ]]; then
            echo -e "\n\nInstalling new packages"
            echo "New packages to install: ${CONFIG_INIT_PACMAN_PACKAGES[*]}"
            pacman -S --noconfirm --needed "${CONFIG_INIT_PACMAN_PACKAGES[*]}"
            echo "New packages installed"
        else
            echo "CONFIG_INIT_PACMAN_PACKAGES is not defined or is not an array"
            read -n 1 -s -r -p "Press any key to continue"
        fi
    fi

    # Pacman - cleanup
    echo -e "\n\nRemoving orphaned packages"
    pacman -Qtdq | pacman --noconfirm -Rns -
    echo "Orphaned packages removed"

    echo -e "\n\nRemoving unneded cached packages"
    paccache -rk1
    paccache -ruk0
    echo "Unneded cached packages removed"

    # Rpi - EEPROM update
    if check_config "CONFIG_INIT_EEPROM_BRANCH_CHANGE"; then
        echo -e "\n\nChanging Rpi EEPROM update channel to '${CONFIG_INIT_EEPROM_UPDATE_BRANCH:-stable}'"
        sed -i 's/FIRMWARE_RELEASE_STATUS=".*"/FIRMWARE_RELEASE_STATUS="'"${CONFIG_INIT_EEPROM_UPDATE_BRANCH:-stable}"'"/g' "${EEPROM_UPDATE_F}"
        echo "Rpi EEPROM update channel changed"
    fi

    echo -e "\n\nChecking for Rpi EEPROM updates"
    if command -v rpi-eeprom-update &>/dev/null; then
        rpi-eeprom-update -d -a
        echo "Rpi EEPROM updates checked"
    else
        echo "rpi-eeprom-update command missing"
        read -n 1 -s -r -p "Press any key to continue"
    fi

    # Rpi - Overclock
    if check_config "CONFIG_INIT_ENABLE_OVERCLOCK"; then
        echo -e "\n\nSetting overclock"
        if ! grep -q "# Overclock-${1}" "${BOOT_CONF_F}"; then
            echo "Overclock config not found"
            cp -a "${BOOT_CONF_F}" "${BOOT_CONF_F}.bak"
            echo "Boot config file backed up at ${BOOT_CONF_F}.bak"
            echo \
                "# Overclock-${1}
    over_voltage=${CONFIG_INIT_OVERCLOCK_OVER_VOLTAGE:-6}
    arm_freq=${CONFIG_INIT_OVERCLOCK_ARM_FREQ:-2000}
    gpu_freq=${CONFIG_INIT_OVERCLOCK_ARM_FREQ:-750}" | tee -a "${BOOT_CONF_F}" >/dev/null
            echo "Overclock will be applied at the next boot"
        else
            echo "Overclock config is already present in ${BOOT_CONF_F}, please check"
            read -n 1 -s -r -p "Press any key to continue"
        fi
    fi

    # Add user to groups
    if check_config "CONFIG_INIT_ADD_USER_TO_GROUPS"; then
        if [[ -v CONFIG_INIT_GROUPS_TO_ADD[@] ]]; then
            echo -e "\n\nAdding ${1} to ${CONFIG_INIT_GROUPS_TO_ADD[*]} groups"
            for group in "${CONFIG_INIT_GROUPS_TO_ADD[@]}"; do
                usermod -aG "${group}" "${1}"
            done
        else
            echo "CONFIG_INIT_GROUPS_TO_ADD is not defined or is not an array"
            read -n 1 -s -r -p "Press any key to continue"
        fi
    fi

    # Nano - enable syntax highlighting
    if check_config "CONFIG_INIT_NANO_ENABLE_SYNTAX_HIGHLIGHTING"; then
        echo -e "\n\nEnabling Nano Syntax highlighting for root and ${1}"
        if [ ! -f "${NANO_CONF_ROOT_F}" ] || ! grep -q 'include "/usr/share/nano/\*.nanorc' "${NANO_CONF_ROOT_F}"; then
            echo -e 'include "/usr/share/nano/*.nanorc"\nset linenumbers' | tee -a "${NANO_CONF_ROOT_F}" >/dev/null
        else
            echo "${NANO_CONF_ROOT_F} already configured"
            read -n 1 -s -r -p "Press any key to continue"
        fi
        if [ ! -f "${NANO_CONF_USER_F}" ] || ! grep -q 'include "/usr/share/nano/\*.nanorc' "${NANO_CONF_USER_F}"; then
            echo -e 'include "/usr/share/nano/*.nanorc"\nset linenumbers' | sudo -u "${1}" tee -a "${NANO_CONF_USER_F}" >/dev/null
        else
            echo "${NANO_CONF_USER_F} already configured"
            read -n 1 -s -r -p "Press any key to continue"
        fi
        echo -e "\nNano Syntax highlighting enabled"
    fi

    # Sudo without password
    if check_config "CONFIG_INIT_SUDO_WITHOUT_PWD"; then
        echo -e "\n\nSetting sudo without password for ${1}"
        if [ ! -f "${SUDOERS_F}" ]; then
            echo "${SUDOERS_F} doesn't exist."
            echo "${1} ALL=(ALL) NOPASSWD: ALL" | tee "${SUDOERS_F}" >/dev/null
            chmod 750 "${SUDOERS_F}"
            echo "${1} can run sudo without password from the next boot."
        else
            echo "${SUDOERS_F} already exists, please check"
            read -n 1 -s -r -p "Press any key to continue"
        fi
    fi

    # Network - optimizationss
    if check_config "CONFIG_INIT_NETWORK_OPTIMIZATIONS"; then
        echo -e "\n\nAdding network confs to ${NETWORK_SYSCTL_CONF_F}"
        echo \
            "# Improve Network performance
# This sets the max OS receive buffer size for all types of connections.
net.core.rmem_max = 8388608
# This sets the max OS send buffer size for all types of connections.
net.core.wmem_max = 8388608" | tee -a "${NETWORK_SYSCTL_CONF_F}" >/dev/null
        echo "Network optimizations done"
    fi

    # Network - enable routing
    if check_config "CONFIG_INIT_NETWORK_ROUTING_ENABLE"; then
        echo -e "\n\nAdding network confs to ${NETWORK_SYSCTL_CONF_F}"
        echo "net.ipv4.ip_forward = 1" | tee -a "${NETWORK_SYSCTL_CONF_F}" >/dev/null
        echo "Routing enabled"
    fi

    # SSD - enable trim
    if check_config "CONFIG_INIT_TRIM_ENABLE"; then
        echo -e "\n\nAdding fstrim conf to ${TRIM_RULES_F}"
        echo "Configured vendor: ${CONFIG_INIT_TRIM_VENDOR:-04e8} | product: ${CONFIG_INIT_TRIM_PRODUCT:-61f5}"
        echo "Please check with command lsusb if they are correct for your SSD device"
        read -n 1 -s -r -p "Press any key to continue"
        echo -e 'ACTION=="add|change", ATTRS{idVendor}=="'"${CONFIG_INIT_TRIM_VENDOR:-04e8}"'", ATTRS{idProduct}=="'"${CONFIG_INIT_TRIM_PRODUCT:-61f5}"'", SUBSYSTEM=="scsi_disk", ATTR{provisioning_mode}="unmap"' | tee "${TRIM_RULES_F}" >/dev/null
        udevadm control --reload-rules
        udevadm trigger
        fstrim -av
        systemctl enable --now fstrim.timer
        echo "Trim enabled"
    fi

    # NTP - custom config
    if check_config "CONFIG_INIT_NTP_CUSOMIZATION"; then
        if systemctl is-active --quiet systemd-timesyncd; then
            echo -e "\n\nTimesyncd setup"
            echo "NTP server: ${CONFIG_INIT_NTP_SERVERS:-time.cloudflare.com}"
            echo "NTP fallback server: ${CONFIG_INIT_NTP_FALLBACK_SERVERS:-pool.ntp.org}"
            mkdir -p "${TIMESYNCD_CONFS_D}"
            echo \
                "# See timesyncd.conf(5) for details.
[Time]
NTP=${CONFIG_INIT_NTP_SERVERS:-time.cloudflare.com}
FallbackNTP=${CONFIG_INIT_NTP_FALLBACK_SERVERS:-pool.ntp.org}
#RootDistanceMaxSec=5
#PollIntervalMinSec=32
#PollIntervalMaxSec=2048
#ConnectionRetrySec=30
#SaveIntervalSec=60" | tee "${TIMESYNCD_CONF_F}" >/dev/null
            systemctl restart systemd-timesyncd
            echo "Timesyncd setup done"
        else
            echo "systemd-timesyncd is not running, maybe this OS is not using it for timesync, config not applied, please check"
            read -n 1 -s -r -p "Press any key to continue"
        fi

    fi

    # SSH
    # echo -e "\n\nAdding ssh user configs"
    # mkdir -p "${SSH_ROOT_D}"
    # sudo -u "${1}" mkdir -p "${SSH_USER_D}"
    # chmod 700 "${SSH_ROOT_D}" "${SSH_USER_D}"
    # echo -e "Please insert public SSH key for ${1} and press Enter\nEG: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB8Ht8Z3j6yDWPBHQtOp/R9rjWvfMYo3MSA/K6q8D86r"
    # read -r
    # echo "${REPLY}" | sudo -u "${1}" tee -a "${SSH_AUTHORIZED_KEY_USER_F}" >/dev/null
    # echo -e "Please insert public SSH key for root user and press Enter\nKeep blank to skip\nEG: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB8Ht8Z3j6yDWPBHQtOp/R9rjWvfMYo3MSA/K6q8D86r"
    # read -r
    # echo "${REPLY}" | tee -a "${SSH_AUTHORIZED_KEY_ROOT_F}" >/dev/null

    echo -e "\n\nAdding useful known hosts"
    ssh-keyscan "${SSH_USEFUL_HOSTS[@]}" | tee "${SSH_KNOWN_HOSTS_ROOT_F}" >/dev/null
    mkdir -p "${SSH_USER_D}"
    cp "${SSH_KNOWN_HOSTS_ROOT_F}" "${SSH_KNOWN_HOSTS_USER_F}"
    chown "${1}:${1}" "${SSH_KNOWN_HOSTS_USER_F}"
    chmod 600 "${SSH_AUTHORIZED_KEY_ROOT_F}" "${SSH_AUTHORIZED_KEY_USER_F}" "${SSH_KNOWN_HOSTS_ROOT_F}" "${SSH_KNOWN_HOSTS_USER_F}"

    # echo -e "\n\nHardening SSH\nhttps://www.ssh-audit.com/hardening_guides.html for details"
    # rm -rf "${SSH_CONF_D}"/ssh_host_*
    # ssh-keygen -t rsa -b 4096 -f "${SSH_CONF_D}/ssh_host_rsa_key" -N ""
    # ssh-keygen -t ed25519 -f "${SSH_CONF_D}/ssh_host_ed25519_key" -N ""
    # awk '$5 >= 3071' "${SSH_CONF_D}/moduli" >"${SSH_CONF_D}/moduli.safe"
    # mv "${SSH_CONF_D}/moduli.safe" "${SSH_CONF_D}/moduli"
    # mv "${SSH_CONF_F}" "${SSH_CONF_F}.bak"
    # echo "${SSH_CONF_F} backed up to ${SSH_CONF_F}.bak"
    # #TODO
    # echo -e "\n\nPlease paste and save the new sshd_config"
    # read -n 1 -s -r -p "Press any key to continue"
    # nano "${SSH_CONF_F}"
    # echo -e "\n\nPlease test the new sshd_config before rebooting\nIf the command sudo sshd -t has no output the config is ok, otherway check it"

    # MacVLAN host <-> docker bridge
    echo -e "\n\nMacVLAN setup"
    echo \
        "[Match]
Name=${LAN_INTERFACE}

[Network]
MACVLAN=macvlan-${1}" | tee "${SYSTEMD_NETWORK_D}/${LAN_INTERFACE}.network" >/dev/null

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
Destination=${MACVLAN_RANGE}

[Network]
DHCP=no
Address=${MACVLAN_STATIC_IP}/32
IPForward=yes
ConfigureWithoutCarrier=yes" | tee "${SYSTEMD_NETWORK_D}/macvlan-${1}.network" >/dev/null
    echo -e "# Custom config by ${1}\ndenyinterfaces macvlan-${1}" | tee -a "${DHCPD_CONF_F}" >/dev/null
    echo -e "[Service]\nExecStart=\nExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any" | SYSTEMD_EDITOR="tee" systemctl edit systemd-networkd-wait-online.service
    systemctl daemon-reload
    echo -e "\nMacVLAN setup done"

    # Services
    echo -e "\n\nEnabling and starting Bluetooth service"
    systemctl enable --now bluetooth
    echo -e "\nBluetooth service enabled & started"

    echo -e "\n\nEnabling Docker service"
    systemctl enable docker.service #  FIXME: Failed to enable unit: File docker.service: Is a directory
    echo -e "\nDocker service enabled"

    # DNS
    echo -e "\n\nAdding systemd-resolved configs"
    mkdir -p "${RESOLVED_CONFS_D}"
    if [ ! -f "${RESOLVED_CONF_F}" ]; then
        echo \
            "# See resolved.conf(5) for details.
[Resolve]
DNS=${DNS_FIRST_PASS}
FallbackDNS=${FALLBACK_DNS}
#Domains=
DNSSEC=${DNS_SEC_FIRST_PASS}
#DNSOverTLS=no
#MulticastDNS=yes
#LLMNR=yes
#Cache=yes
#CacheFromLocalhost=no
DNSStubListener=no
#DNSStubListenerExtra=
#ReadEtcHosts=yes
#ResolveUnicastSingleLabel=no" | tee "${RESOLVED_CONF_F}"SSH_CONF_D >/dev/null
    else
        echo "${RESOLVED_CONF_F} already exists, please check"
    fi

    echo -e "\n\nSetting systemd-resolved in uplink mode"
    mv -f "${RESOLV_CONF_F}" "${RESOLV_CONF_F}.bak"
    echo "${RESOLV_CONF_F} backed up to ${RESOLV_CONF_F}.bak"
    ln -s "${STUB_RESOLV_F}" "${RESOLV_CONF_F}"
    echo -e "\nsystemd-resolved in now configured in uplink mode"
    systemctl restart systemd-resolved

    # Disable IPv6
    echo -e "\n\nDisabling IPv6"
    cp -a "${BOOT_CMDLINE_F}" "${BOOT_CMDLINE_F}.bak"
    echo "Boot cmdline file backed up at ${BOOT_CMDLINE_F}.bak"
    sed -i 's/$/ ipv6.disable_ipv6=1/g' "${BOOT_CMDLINE_F}"
    echo \
        "# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1" | tee -a "${NETWORK_SYSCTL_CONF_F}" >/dev/null
    echo \
        "LinkLocalAddressing=no
IPv6AcceptRA=no" | tee -a "${SYSTEMD_NETWORK_D}/${LAN_INTERFACE}.network" >/dev/null
    echo \
        "LinkLocalAddressing=no
IPv6AcceptRA=no" | tee -a "${SYSTEMD_NETWORK_D}/macvlan-${1}.network" >/dev/null
    echo \
        "ipv4only
noipv6rs
noipv6" | tee -a "${DHCPD_CONF_F}" >/dev/null
    echo "IPv6 disabled"

    # Filesystem optimizations
    # echo -e "\n\nFilesystem SSD optimizations"
    # cp -a /etc/fstab /etc/fstab.bak
    # echo "/etc/fstab backed up to /etc/fstab.bak"
    # sed -i 's/defaults/defaults,noatime/g' /etc/fstab
    # echo "Filesystem optimizations done"

    # Pass 1 done
    echo "1" | sudo -u "${1}" tee "${SCRIPT_HELPER_F}"
    echo -e "\n\nFirst part of the config done"
    echo "Please check sshd config using 'sudo sshd -t' command and fix any problem before rebooting"
    echo "If the command sudo sshd -t has no output the config is ok"
    echo "Reboot and run this script again to finalize the configuration"
    exit 0
fi

# Second pass
if [ -f "${SCRIPT_HELPER_F}" ] && [[ $(<"${SCRIPT_HELPER_F}") == "1" ]]; then
    echo "Second init pass"

    # Docker login
    echo -e "\n\nDocker login"
    read -n 1 -s -r -p "Prepare docker hub user and password. Press any key to continue"
    echo ""
    sudo -u "${1}" docker login

    # Docker custom bridge network
    echo -e "\n\nCreating Docker networks"
    sudo -u "${1}" docker network create "bridge_${1}"
    sudo -u "${1}" docker network create -d macvlan --subnet="${MACVLAN_SUBNET}" --ip-range="${MACVLAN_RANGE}" --gateway="${MACVLAN_GATEWAY}" -o parent="${LAN_INTERFACE}" --aux-address="macvlan_bridge=${MACVLAN_STATIC_IP}" "macvlan_${1}"
    echo -e "\nDocker networks created"

    # Restore backup
    echo -e "\n\nRestoring backup"
    if [ ! -f "${BACKUP_F}" ]; then
        echo -e "\nCannot find ${BACKUP_F}, please check, exiting"
        exit 5
    else
        tar --same-owner -xf "${BACKUP_F}" -C /
        sudo -u "${1}" docker compose -f "${HOME_USER_D}/docker/docker-compose.yml" up -d
        echo -e "\nPortainer should be up and running, start other stacks from there"
    fi
    echo "2" | sudo -u "${1}" tee "${SCRIPT_HELPER_F}"
    echo -e "\n\nSecond part of the config done"
    exit 0
fi

exit 0
