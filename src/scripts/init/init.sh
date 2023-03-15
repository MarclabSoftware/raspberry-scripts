#!/usr/bin/env bash

# Bash colors
RED='\033[0;31m'   # Red color
GREEN='\033[0;32m' # Green color
NC='\033[0m'       # No color

# Script related vars
SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
SCRIPT_NAME=$(basename "$(readlink -f "$0")" .sh)
CONFIG_F="$SCRIPT_D/$SCRIPT_NAME.conf"

# External scripts
UTILS_F="$SCRIPT_D/utils.sh"
RFKILL_F="$SCRIPT_D/rfkill.sh"
JOURNAL_LIMIT_F="$SCRIPT_D/journal_limit.sh"
SWAPPINESS_F="$SCRIPT_D/swappiness.sh"
PACMAN_COUNTRIES_F="$SCRIPT_D/pacman_countries.sh"
PACMAN_COLORS_F="$SCRIPT_D/pacman_colors.sh"
PACMAN_INSTALL_PKGS_F="$SCRIPT_D/pacman_install_pkgs.sh"
PACMAN_CLEANUP_F="$SCRIPT_D/pacman_cleanup.sh"
RPI_EEPROM_BRANCH_F="$SCRIPT_D/rpi_eeprom_branch.sh"
RPI_EEPROM_UPDATE_F="$SCRIPT_D/rpi_eeprom_update.sh"
RPI_OVERCLOCK_F="$SCRIPT_D/rpi_overclock.sh"
USER_GROUPS_F="$SCRIPT_D/user_groups.sh"
USER_PASSWRODLESS_SUDO="$SCRIPT_D/user_passwordless_sudo.sh"
NANO_SYNTAX_HIGHLIGHTING_F="$SCRIPT_D/nano_syntax_highlighting.sh"
NETWORK_OPTIMIZATIONS_F="$SCRIPT_D/network_optimization.sh"
NETWORK_ROUTING_F="$SCRIPT_D/network_routing.sh"
NETWORK_MACVLAN_F="$SCRIPT_D/network_macvlan.sh"
NETWORK_IPV6_DISABLE_F="$SCRIPT_D/network_ipv6_disable.sh"
SSD_TRIM_F="$SCRIPT_D/ssd_trim.sh"
SSD_OPTIMIZATIONS_F="$SCRIPT_D/ssd_optimizations.sh"
NTP_F="$SCRIPT_D/ntp.sh"
SSH_PREPARE_F="$SCRIPT_D/ssh_prepare.sh"

# Source utils
# shellcheck source=utils.sh
. "$UTILS_F"

clear

# Safety checks
if ! checkSU; then
    echo "This script must be run as super user"
    exit 1
fi

# Import config file
if [ -f "$CONFIG_F" ]; then
    echo "Config file found... importing it"
    # shellcheck source=init.conf
    . "$CONFIG_F"
else
    echo "Config file not found... proceeding to manual config"
fi

if isVarEmpty "$CONFIG_USER"; then
    echo -e "\nMissing CONFIG_USER, please enter the normal user name and press enter\n"
    read -r
    CONFIG_USER="$REPLY"
fi

if ! isNormalUser "$CONFIG_USER"; then
    echo -e "\nCONFIG_USER problem, it must be set, it must be a normal user, it must exists"
    exit 1
fi

# Constants
HOME_USER_D=$(sudo -u "$CONFIG_USER" sh -c 'echo $HOME')
HOME_ROOT_D=$(sudo -u root sh -c 'echo $HOME')
HELPER_F="$HOME_USER_D/.${SCRIPT_NAME}_progress"
RESOLVED_CONFS_D="/etc/systemd/resolved.conf.d"
RESOLVED_CONF_F="$RESOLVED_CONFS_D/resolved-$CONFIG_USER.conf"
RESOLV_CONF_F="/etc/resolv.conf"
STUB_RESOLV_F="/run/systemd/resolve/stub-resolv.conf"
SSH_ROOT_D="$HOME_ROOT_D/.ssh"
SSH_USER_D="$HOME_USER_D/.ssh"
SSH_CONF_D="/etc/ssh"
SSH_CONF_F="$SSH_CONF_D/sshd_config"
SSH_AUTHORIZED_KEY_USER_F="$SSH_USER_D/authorized_keys"
SSH_AUTHORIZED_KEY_ROOT_F="$SSH_ROOT_D/authorized_keys"
SSH_KNOWN_HOSTS_USER_F="$SSH_USER_D/known_hosts"
SSH_KNOWN_HOSTS_ROOT_F="$SSH_ROOT_D/known_hosts"

# Create helper file if not found
if [ ! -f "$HELPER_F" ]; then
    echo "0" | sudo -u "$CONFIG_USER" tee "$HELPER_F" >/dev/null
fi

helper_f_content=$(<"$HELPER_F")

if [[ "$helper_f_content" == "2" ]]; then
    echo "All config already done, exiting."
    exit 3

# First pass
elif [[ "$helper_f_content" == "0" ]]; then

    echo -e "\nFirst init pass"

    # Rfkill - block wireless devices
    if checkConfig "CONFIG_INIT_RFKILL"; then
        # shellcheck source=rfkill.sh
        . "$RFKILL_F"
        blockRf
    fi

    # Journal - limit size
    if checkConfig "CONFIG_INIT_JOURNAL_LIMIT"; then
        # shellcheck source=journal_limit.sh
        . "$JOURNAL_LIMIT_F"
        limitJournal
    fi

    # RAM - set swappiness
    if checkConfig "CONFIG_INIT_RAM_SWAPPINESS_CUSTOMIZE"; then
        # shellcheck source=swappiness.sh
        . "$SWAPPINESS_F"
        setSwappiness
    fi

    # Pacman - set mirrors
    if checkConfig "CONFIG_INIT_PACMAN_SET_MIRROR_COUNTRIES"; then
        # shellcheck source=pacman_countries.sh
        . "$PACMAN_COUNTRIES_F"
        setPacmanCountries
    fi

    # Pacman - update
    echo -e "\n\nUpdating packages"
    # TODO: noconfirm doesn't work with packages like linux-rpi4-mainline due to incompatibilites with installed packages
    pacman -Syyuu
    echo "Packages updated"

    # Pacman - enable colored output
    if checkConfig "CONFIG_INIT_PACMAN_ENABLE_COLORS"; then
        # shellcheck source=pacman_colors.sh
        . "$PACMAN_COLORS_F"
        setPacmanColors
    fi

    # Pacman - install packages
    if checkConfig "CONFIG_INIT_PACMAN_INSTALL_PACKAGES"; then
        # shellcheck source=pacman_install_pkgs.sh
        . "$PACMAN_INSTALL_PKGS_F"
        installPacmanPackages
    fi

    # Pacman - cleanup
    if checkConfig "CONFIG_INIT_PACMAN_CLEANUP"; then
        # shellcheck source=pacman_cleanup.sh
        . "$PACMAN_CLEANUP_F"
        pacmanCleanup
    fi

    # Rpi - EEPROM update branch
    if checkConfig "CONFIG_INIT_RPI_EEPROM_BRANCH_CHANGE"; then
        # shellcheck source=rpi_eeprom_branch.sh
        . "$RPI_EEPROM_BRANCH_F"
        changeEepromBranch
    fi

    # Rpi - EEPROM update check
    if checkConfig "CONFIG_INIT_RPI_EEPROM_UPDATE_CHECK"; then
        # shellcheck source=rpi_eeprom_update.sh
        . "$RPI_EEPROM_UPDATE_F"
        updateEeprom
    fi

    # Rpi - Overclock
    if checkConfig "CONFIG_INIT_RPI_OVERCLOCK_ENABLE"; then
        # shellcheck source=rpi_overclock.sh
        . "$RPI_OVERCLOCK_F"
        goFaster
    fi

    # User - add to groups
    if checkConfig "CONFIG_INIT_USER_ADD_TO_GROUPS"; then
        # shellcheck source=user_groups.sh
        . "$USER_GROUPS_F"
        adsUserToGroups
    fi

    # User - sudo without password
    if checkConfig "CONFIG_INIT_USER_SUDO_WITHOUT_PWD"; then
        # shellcheck source=user_passwordless_sudo.sh
        . "$USER_PASSWRODLESS_SUDO"
        enablePasswordlessSudo
    fi

    # Nano - enable syntax highlighting
    if checkConfig "CONFIG_INIT_NANO_ENABLE_SYNTAX_HIGHLIGHTING"; then
        # shellcheck source=nano_syntax_highlighting.sh
        . "$NANO_SYNTAX_HIGHLIGHTING_F"
        enableNanoSyntaxHighlighting
    fi

    # Network - optimizations
    if checkConfig "CONFIG_INIT_NETWORK_OPTIMIZATIONS"; then
        # shellcheck source=network_optimization.sh
        . "$NETWORK_OPTIMIZATIONS_F"
        optimizeNetwork
    fi

    # Network - enable routing
    if checkConfig "CONFIG_INIT_NETWORK_ROUTING_ENABLE"; then
        # shellcheck source=network_routing.sh
        . "$NETWORK_ROUTING_F"
        enableRouting
    fi

    # Network - MACVLAN host <-> docker bridge
    if checkConfig "CONFIG_INIT_NETWORK_MACVLAN_SETUP"; then
        # shellcheck source=network_macvlan.sh
        . "$NETWORK_MACVLAN_F"
        enableMacVlan
    fi

    # Network - IPv6 Disable
    if checkConfig "CONFIG_INIT_NETWORK_IPV6_DISABLE"; then
        # shellcheck source=network_ipv6_disable.sh
        . "$NETWORK_IPV6_DISABLE_F"
        disableIpv6
    fi

    # SSD - enable trim
    if checkConfig "CONFIG_INIT_SSD_TRIM_ENABLE"; then
        # shellcheck source=ssd_trim.sh
        . "$SSD_TRIM_F"
        enableTrim
    fi

    # SSD - FS optimizations
    if checkConfig "CONFIG_INIT_SSD_OPTIMIZATIONS"; then
        # shellcheck source=ssd_optimizations.sh
        . "$SSD_OPTIMIZATIONS_F"
        optimizeFs
    fi

    # NTP - custom config
    if checkConfig "CONFIG_INIT_NTP_CUSTOMIZATION"; then
        # shellcheck source=ntp.sh
        . "$NTP_F"
        customNtp
    fi

    # SSH - prepare
    # shellcheck source=ssh_prepare.sh
    . "$SSH_PREPARE_F"
    prepareSSH

    # SSH - add keys
    if checkConfig "CONFIG_INIT_SSH_KEYS_ADD"; then
        echo -e "\n\nAdding SSH keys"
        echo -e "Please insert public SSH key for $CONFIG_USER and press Enter\nEG: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB8Ht8Z3j6yDWPBHQtOp/R9rjWvfMYo3MSA/K6q8D86r"
        read -r
        echo "$REPLY" | sudo -u "$CONFIG_USER" tee -a "$SSH_AUTHORIZED_KEY_USER_F" >/dev/null
        echo -e "Please insert public SSH key for root user and press Enter\nKeep blank to skip\nEG: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB8Ht8Z3j6yDWPBHQtOp/R9rjWvfMYo3MSA/K6q8D86r"
        read -r
        echo "$REPLY" | tee -a "$SSH_AUTHORIZED_KEY_ROOT_F" >/dev/null
        echo "SSH keys added"
    fi

    # SSH - add hosts
    if checkConfig "CONFIG_INIT_SSH_HOSTS_ADD"; then
        echo -e "\n\nAdding SSH useful known hosts"
        ssh-keyscan "${CONFIG_SSH_HOSTS[@]}" | tee "$SSH_KNOWN_HOSTS_ROOT_F" >/dev/null
        mkdir -p "$SSH_USER_D"
        cp "$SSH_KNOWN_HOSTS_ROOT_F" "$SSH_KNOWN_HOSTS_USER_F"
        chown "$CONFIG_USER:$CONFIG_USER" "$SSH_KNOWN_HOSTS_USER_F"
        chmod 600 "$SSH_AUTHORIZED_KEY_ROOT_F" "$SSH_AUTHORIZED_KEY_USER_F" "$SSH_KNOWN_HOSTS_ROOT_F" "$SSH_KNOWN_HOSTS_USER_F"
        echo "SSH useful known hosts added"
    fi

    if checkConfig "CONFIG_INIT_SSH_HARDENING"; then
        echo -e "\n\nHardening SSH\nhttps://www.ssh-audit.com/hardening_guides.html for details"
        rm -rf "$SSH_CONF_D"/ssh_host_*
        ssh-keygen -t rsa -b 4096 -f "$SSH_CONF_D/ssh_host_rsa_key" -N ""
        ssh-keygen -t ed25519 -f "$SSH_CONF_D/ssh_host_ed25519_key" -N ""
        awk '$5 >= 3071' "$SSH_CONF_D/moduli" >"$SSH_CONF_D/moduli.safe"
        mv "$SSH_CONF_D/moduli.safe" "$SSH_CONF_D/moduli"
        mv "$SSH_CONF_F" "$SSH_CONF_F.bak"
        echo "$SSH_CONF_F backed up to $SSH_CONF_F.bak"
        #TODO
        echo -e "\n\nPlease paste and save the new sshd_config"
        paktc
        nano "$SSH_CONF_F"
        echo -e "\n\nPlease test the new sshd_config before rebooting\nIf the command sudo sshd -t has no output the config is ok, otherway check it"
    fi

    # Services - bluetooth
    if checkConfig "CONFIG_INIT_SRV_BT_ENABLE"; then
        echo -e "\n\nEnabling and starting Bluetooth service"
        systemctl enable --now bluetooth
        echo -e "\nBluetooth service enabled & started"
    fi

    # Services - docker
    if checkConfig "CONFIG_INIT_SRV_DOCKER_ENABLE"; then
        echo -e "\n\nEnabling Docker service"
        systemctl enable docker.service #  FIXME: Failed to enable unit: File docker.service: Is a directory
        echo -e "\nDocker service enabled"
    fi

    # DNS
    if checkConfig "CONFIG_INIT_DNS_CUSTOMIZATION"; then
        echo -e "\n\nAdding DNS systemd-resolved configs"
        mkdir -p "$RESOLVED_CONFS_D"
        if [ ! -f "$RESOLVED_CONF_F" ]; then
            echo \
                "# See resolved.conf(5) for details.
[Resolve]
DNS=$CONFIG_DNS_SRVS
FallbackDNS=$CONFIG_DNS_FALLBACK_SRVS
#Domains=
DNSSEC=$CONFIG_DNS_DNSSEC
#DNSOverTLS=no
#MulticastDNS=yes
#LLMNR=yes
#Cache=yes
#CacheFromLocalhost=no
DNSStubListener=no
#DNSStubListenerExtra=
#ReadEtcHosts=yes
#ResolveUnicastSingleLabel=no" | tee "$RESOLVED_CONF_F" >/dev/null
            echo "DNS systemd-resolved configs added"
        else
            echo "$RESOLVED_CONF_F already exists, please check"
            paktc
        fi
    fi
    if checkConfig "CONFIG_INIT_DNS_UPLINK_MODE"; then
        echo -e "\n\nSetting systemd-resolved in uplink mode"
        mv -f "$RESOLV_CONF_F" "$RESOLV_CONF_F.bak"
        echo "$RESOLV_CONF_F backed up to $RESOLV_CONF_F.bak"
        ln -s "$STUB_RESOLV_F" "$RESOLV_CONF_F"
        echo -e "\nsystemd-resolved in now configured in uplink mode"
        systemctl restart systemd-resolved
    fi

    # Pass 1 done
    echo "1" | sudo -u "$CONFIG_USER" tee "$HELPER_F"
    echo -e "\n\nFirst part of the config done"
    echo "Please check sshd config using 'sudo sshd -t' command and fix any problem before rebooting"
    echo "If the command sudo sshd -t has no output the config is ok"
    echo "Reboot and run this script again to finalize the configuration"
    exit 0

# Second pass
elif [[ "$helper_f_content" == "1" ]]; then
    echo "Second init pass"

    # Docker - login
    if checkConfig "CONFIG_INIT_DOCKER_LOGIN"; then
        echo -e "\n\nDocker login"
        echo "Please prepare docker hub user and password"
        paktc
        sudo -u "$CONFIG_USER" docker login
    fi

    # Docker - custom bridge network
    if checkConfig "CONFIG_INIT_DOCKER_NETWORK_ADD_CUSTOM_BRIDGE"; then
        echo -e "\n\nCreating Docker custom bridge network bridge_$CONFIG_USER"
        sudo -u "$CONFIG_USER" docker network create "bridge_$CONFIG_USER"
        echo "Docker custom bridge network created"
    fi

    # Docker - add MACVLAN network
    if checkConfig "CONFIG_INIT_DOCKER_NETWORK_ADD_MACVLAN"; then
        echo -e "\n\nCreating Docker custom MACVLAN network macvlan_$CONFIG_USER"
        sudo -u "$CONFIG_USER" docker network create "bridge_$CONFIG_USER"
        sudo -u "$CONFIG_USER" docker network create -d macvlan \
            --subnet="$CONFIG_NETWORK_MACVLAN_SUBNET" \
            --ip-range="$CONFIG_NETWORK_MACVLAN_RANGE" \
            --gateway="$CONFIG_NETWORK_MACVLAN_GATEWAY" \
            -o parent="$CONFIG_NETWORK_MACVLAN_PARENT" \
            --aux-address="macvlan_bridge=$CONFIG_NETWORK_MACVLAN_STATIC_IP" \
            "macvlan_$CONFIG_USER"
        echo "Docker custom MACVLAN network created"
    fi

    # Backup - restore
    if checkConfig "CONFIG_INIT_BACKUP_RESTORE"; then
        echo -e "\n\nRestoring backup"
        if [ ! -f "$CONFIG_BACKUP_FILE_PATH" ]; then
            echo -e "\nCannot find $CONFIG_BACKUP_FILE_PATH, please check"
            paktc
        else
            tar --same-owner -xf "$CONFIG_BACKUP_FILE_PATH" -C /
        fi
    fi

    if checkConfig "CONFIG_INIT_DOCKER_COMPOSE_START"; then
        echo -e "\n\nStarting docker compose"
        if [ -f "$CONFIG_DOCKER_COMPOSE_FILE_PATH" ]; then
            sudo -u "$CONFIG_USER" docker compose -f "$CONFIG_DOCKER_COMPOSE_FILE_PATH" up -d
            echo -e "\nServices in $CONFIG_DOCKER_COMPOSE_FILE_PATH compose file should be up and running"
        else
            echo "Cannot find $CONFIG_DOCKER_COMPOSE_FILE_PATH compose file, please check"
            paktc
        fi
    fi

    echo "2" | sudo -u "$CONFIG_USER" tee "$HELPER_F"
    echo -e "\n\nSecond part of the config done"
    exit 0
fi

exit 0
