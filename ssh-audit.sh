#!/usr/bin/env bash

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "Please run as normal user"
    exit 1
fi

HOME="/home/${USER}"
FILENAME="ssh-audit-master"
FULLPATH="${HOME}/${FILENAME}"

cd "${HOME}" || exit 1
rm -rf "${FULLPATH}"
curl -o "${FULLPATH}.zip" -OL https://github.com/jtesta/ssh-audit/archive/refs/heads/master.zip
unzip "${FULLPATH}.zip"
rm -f "${FULLPATH}.zip"
"${FULLPATH}/ssh-audit.py" localhost
#"${FULLPATH}/ssh-audit.py" -L
#"${FULLPATH}/ssh-audit.py" -P "Hardened Ubuntu Server 22.04 LTS (version 1)" localhost

exit 0