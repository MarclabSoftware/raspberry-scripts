#!/usr/bin/env bash

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
SSH_ADD_KEYS_F="$SCRIPT_D/ssh_add_keys.sh"
SSH_ADD_HOSTS_F="$SCRIPT_D/ssh_add_hosts.sh"
SSH_HARDENING_F="$SCRIPT_D/ssh_hardening.sh"
DNS_F="$SCRIPT_D/dns.sh"

# Source utils
# shellcheck source=utils.sh
. "$UTILS_F"

clear

# Safety checks
checkSU || exit 1

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
        # shellcheck source=ssh_add_keys.sh
        . "$SSH_ADD_KEYS_F"
        addSSHKeys
    fi

    # SSH - add hosts
    if checkConfig "CONFIG_INIT_SSH_HOSTS_ADD"; then
        # shellcheck source=ssh_add_hosts.sh
        . "$SSH_ADD_HOSTS_F"
        addSSHHosts
    fi

    if checkConfig "CONFIG_INIT_SSH_HARDENING"; then
        # shellcheck source=ssh_hardening.sh
        . "$SSH_HARDENING_F"
        hardenSSH
    fi

    # Services - bluetooth
    if checkConfig "CONFIG_INIT_SRV_BT_ENABLE"; then
        enableService "bluetooth" true
    fi

    # Services - docker
    if checkConfig "CONFIG_INIT_SRV_DOCKER_ENABLE"; then
        enableService "docker" false
    fi

    # DNS
    if checkConfig "CONFIG_INIT_DNS_CUSTOMIZATION"; then
        # shellcheck source=dns.sh
        . "$DNS_F"
        setCustomDNS
    fi

    # Pass 1 done
    echo "1" | tee "$HELPER_F"
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

    echo "2" | tee "$HELPER_F"
    echo -e "\n\nSecond part of the config done"
    exit 0
fi

exit 0
