#!/bin/bash

# Remove outdated letsencrypt CSRs, keys and certificates

LEBasePath="$HOME/docker/npm/letsencrypt"
keepOldVersions=1
keepOldCsrDays=180
keepOldKeysDays=180

if [ ! -d "$LEBasePath" ]; then
    echo "Error: configured Let's Encrypt base path $LEBasePath does not exist" >&2
    exit 1
fi

# cleanup csr directory
if [ -d "$LEBasePath/csr" ]; then
    find "$LEBasePath/csr" -name '*_csr-certbot.pem' -type f -mtime +$keepOldCsrDays -exec rm -f {} ';'
else
    echo "$LEBasePath/csr does not exist, skipping" >&2
fi

# cleanup keys directory
if [ -d "$LEBasePath/keys" ]; then
    find "$LEBasePath/keys" -name '*_key-certbot.pem' -type f -mtime +$keepOldKeysDays -exec rm -f {} ';'
else
    echo "$LEBasePath/keys does not exist, skipping" >&2
fi

function getFileId() {
    local result
    getFileIdResult=-1 # Error
    result=$(expr "$1" : '.*[privkey|cert|chain|fullchain]\(.[0-9]*\).pem$')
    if [ -n "$result" ] && [ "$result" -eq "$result" ] 2>/dev/null; then
        getFileIdResult="$result"
    fi
}

# cleanup archive directory
if [ -d "$LEBasePath/live" ]; then
    for symlink in "$LEBasePath"/live/*/privkey.pem; do
        target=$(readlink -f "$symlink")
        if [ $? -ne 0 ]; then
            continue
        fi
        getFileId "$target"
        if [ "$getFileIdResult" -eq -1 ]; then
            continue
        fi
        cmpId=$((getFileIdResult - keepOldVersions))
        for archivefile in "$(dirname "$target")"/*.pem; do
            getFileId "$archivefile"
            if [ "$getFileIdResult" -eq -1 ]; then
                continue
            fi
            if [ "$getFileIdResult" -lt "$cmpId" ]; then
                echo "Deleting $archivefile"
                rm -f "$archivefile"
            fi
        done
    done
fi

echo "Done"
exit 0
