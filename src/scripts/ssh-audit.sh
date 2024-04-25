#!/usr/bin/env bash

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "Please run as normal user"
    exit 1
fi

URL="https://github.com/jtesta/ssh-audit/archive/refs/heads/master.zip"
FILENAME="ssh-audit-master.zip"
FILEPATH_F="$HOME/$FILENAME"
DIRPATH_D="$HOME/$(basename "$FILEPATH_F" .zip)"

cd "$HOME" || exit 1
rm -rf "$FILEPATH_F" "$DIRPATH_D"
curl -o "$FILEPATH_F" -OL "$URL"
unzip "$FILEPATH_F"
rm -f "$FILEPATH_F"
"$DIRPATH_D/ssh-audit.py" localhost
#"$DIRPATH_D/ssh-audit.py" -L
#"$DIRPATH_D/ssh-audit.py" -P "Hardened OpenSSH Server v9.7 (version 1)" localhost

exit 0
