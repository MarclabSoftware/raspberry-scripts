#!/bin/bash

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "Please run as normal user"
    exit 1
fi

certName="npm-1"
dockerDir="$HOME/docker"
letsencryptDir="$dockerDir/npm/letsencrypt"
technitiumDnsDir="$dockerDir/technitium-dns"
newCertName="certificate"

convertCertificate() {
    sleep 10
    if openssl pkcs12 -export \
        -in "$letsencryptDir/live/$certName/fullchain.pem" \
        -inkey "$letsencryptDir/live/$certName/privkey.pem" \
        -out "$technitiumDnsDir/$newCertName.pfx" \
        -passout pass:"" -passin pass:""; then
        echo "New cert installed: $technitiumDnsDir/$newCertName.pfx"
    fi
}


if [ ! -d "$letsencryptDir/live/$certName" ]; then
    echo "$letsencryptDir/live/$certName dir does not exist, please check, exiting."
    exit 1
fi

if [ ! -d "$technitiumDnsDir" ]; then
    echo "$technitiumDnsDir dir does not exist, please check, exiting."
    exit 2
fi

# Monitor folder files
#testDir="${HOME}/raspberry-scripts/test"
#inotifywait -P -m --format '%:e %f' "${testDir}" #Debug

inotifywait -P -m -e create --format '%f' "$letsencryptDir/live/$certName" | while read -r fileName; do
    if [ "$fileName" == "fullchain.pem" ]; then
        convertCertificate &
    fi
done
