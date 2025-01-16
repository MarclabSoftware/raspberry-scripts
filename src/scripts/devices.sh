#!/bin/bash

# Imposta strict mode per catturare errori
set -euo pipefail

# Funzione per processare ogni dispositivo
process_device() {
    local sysdevpath="$1"
    local syspath="${sysdevpath%/dev}"
    local devname
    local properties

    # Ottiene il nome del device in modo più efficiente
    devname=$(udevadm info -q name -p "$syspath") || return

    # Salta i dispositivi bus
    [[ "$devname" == bus/* ]] && return

    # Ottiene le proprietà in una singola chiamata
    properties=$(udevadm info -q property --export -p "$syspath") || return

    # Estrae ID_SERIAL usando grep invece di eval
    local serial
    serial=$(echo "$properties" | grep '^ID_SERIAL=' | cut -d= -f2)

    # Salta se non c'è serial
    [[ -z "$serial" ]] && return

    echo "/dev/$devname - $serial"
}

export -f process_device

# Usa xargs per processare in parallelo
find /sys/bus/usb/devices/usb*/ -name dev -print0 |
    xargs -0 -I {} -P "$(nproc)" bash -c 'process_device "$@"' _ {}
