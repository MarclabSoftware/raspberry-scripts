#!/usr/bin/env bash

PACMAN_MIRRORS_COUNTRIES="Italy,Global,Germany,Switzerland,Czechia,France,Netherlands,Austria"

# Safety checks
if [ ! "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "Please run as root/sudo"
    echo "Exiting."
    exit 1
fi

echo -e "\n\nUpdating pacman mirrors"
pacman-mirrors --country "$PACMAN_MIRRORS_COUNTRIES"

echo -e "\n\nUpdating packages"
pacman -Syyuu --noconfirm

echo -e "\n\nRemoving orphaned packages"
pacman -Qtdq | pacman --noconfirm -Rns -

echo -e "\n\nRemoving unneded cached packages"
paccache -rk1
paccache -ruk0

echo -e "\n\nUpdating Rpi EEPROM"
rpi-eeprom-update -d -a

echo -e "\n\nUpdating docker node-red npm packages"
docker exec node-red bash -c 'cd /data && npm update'

exit 0
