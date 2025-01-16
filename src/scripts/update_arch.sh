#!/usr/bin/env bash

# Safety checks
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Please run as root/sudo"
    exit 1
fi

BACKUP_FILE="/home/labo/backup.tar.gz"
rm -f "$BACKUP_FILE"
tar -zcvf "$BACKUP_FILE" \
    /boot/config.txt \
    /boot/cmdline.txt \
    /etc/systemd/journald.conf.d/labo-* \
    /etc/systemd/resolved.conf.d/labo-* \
    /etc/systemd/timesyncd.conf.d/labo-* \
    /etc/systemd/network/labo-* \
    /etc/systemd/system/labo-* \
    /etc/sudoers.d/labo \
    /etc/pacman.conf \
    /etc/default/rpi-eeprom-update \
    /etc/sysctl.d \
    /etc/udev/rules.d/trim_samsung.rules \
    /etc/udev/rules.d/66-maxperfwiz.rules \
    /etc/ssh/sshd_config.d/labo.conf \
    /etc/dhcpcd.conf \
    /home/labo/.nanorc \
    /root/.nanorc \
    /home/labo/.ssh \
    /root/.ssh

PACMAN_MIRRORS_COUNTRIES="Italy,Global,Germany,Switzerland,Czechia,France,Netherlands,Austria"
echo -e "\n\nUpdating pacman mirrors"
pacman-mirrors --country "${PACMAN_MIRRORS_COUNTRIES}"

echo -e "\n\nUpdating packages"
pacman -Syyuu --noconfirm

echo -e "\n\nRemoving orphaned packages"
pacman -Qtdq | xargs -r pacman --noconfirm -Rns -

echo -e "\n\nRemoving unneded cached packages"
paccache -rk1
paccache -ruk0

echo -e "\n\nUpdating Rpi EEPROM"
rpi-eeprom-update -d -a

echo -e "\n\nUpdating docker node-red npm packages"
docker exec node-red bash -c 'cd /data && npm update && npm cache clean --force'
docker container restart node-red

echo -e "\n\nDocker cleaning"
DOCKER_BASE_DIR="/home/labo/docker"

if cd "$DOCKER_BASE_DIR/esphome" 2>/dev/null; then
    echo "Cleaning $DOCKER_BASE_DIR/esphome"
    rm -vrf ./build ./platformio
else
    echo "$DOCKER_BASE_DIR/esphome not found, skipping"
fi

if cd "$DOCKER_BASE_DIR/home-assistant" 2>/dev/null; then
    echo "Cleaning $DOCKER_BASE_DIR/home-assistant"
    rm -vf ./home-assistant.log ./home-assistant.log.1 ./home-assistant.log.fault
else
    echo "$DOCKER_BASE_DIR/home-assistant not found, skipping"
fi

if cd "$DOCKER_BASE_DIR/mosquitto" 2>/dev/null; then
    echo -e "Cleaning $DOCKER_BASE_DIR/mosquitto"
    rm -vf ./log/mosquitto.log
else
    echo "$DOCKER_BASE_DIR/mosquitto not found, skipping"
fi

if cd "$DOCKER_BASE_DIR/npm" 2>/dev/null; then
    echo "Cleaning $DOCKER_BASE_DIR/npm"
    rm -vf ./data/logs/*
else
    echo "$DOCKER_BASE_DIR/npm not found, skipping"
fi

if cd "$DOCKER_BASE_DIR/omada" 2>/dev/null; then
    echo "Cleaning $DOCKER_BASE_DIR/omada"
    rm -vf ./logs/*
else
    echo "$DOCKER_BASE_DIR/omada not found, skipping"
fi

if cd "$DOCKER_BASE_DIR/technitium" 2>/dev/null; then
    echo "Cleaning $DOCKER_BASE_DIR/technitium"
    rm -vf ./logs/*
else
    echo "$DOCKER_BASE_DIR/technitium not found, skipping"
fi

if cd "$DOCKER_BASE_DIR/vaultwarden" 2>/dev/null; then
    echo "Cleaning $DOCKER_BASE_DIR/vaultwarden"
    rm -vf ./data/vaultwarden.log
else
    echo "$DOCKER_BASE_DIR/vaultwarden not found, skipping"
fi

if cd "$DOCKER_BASE_DIR/z2m" 2>/dev/null; then
    echo "Cleaning $DOCKER_BASE_DIR/z2m"
    rm -vrf ./log/*
else
    echo "$DOCKER_BASE_DIR/z2m not found, skipping"
fi

exit 0
