#!/usr/bin/env bash

# Vars
AUR_PKG_D="/home/${USER}/aur_packages"
GIT_URL="https://aur.archlinux.org/argonone-c-git.git"

# Functions
gclonecd() {
    git clone "$1" && cd "$(basename "$1" .git)" || exit 2
}

# Main
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "Please run as normal user"
    exit 1
fi

[ -d "${AUR_PKG_D}" ] || mkdir -p "${AUR_PKG_D}"
cd "${AUR_PKG_D}" || exit 1
gclonecd "${GIT_URL}"
makepkg -cfsi

exit 0
