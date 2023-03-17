#!/usr/bin/env bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

rm -rf "$SCRIPT_DIR/build"
mkdir -p "$SCRIPT_DIR/build"

cp "$SCRIPT_DIR/src/bootstrap.sh" "$SCRIPT_DIR/build/rpi-init.sh"

for module in "$SCRIPT_DIR"/src/scripts/* "$SCRIPT_DIR"/src/scripts/**/* ; do
    if [ -f "$module" ]; then
        moduleDir=$(realpath --relative-to="$SCRIPT_DIR/src" "$module")
        echo -e "\n# {{$moduleDir}}" | tee -a "$SCRIPT_DIR/build/rpi-init.sh" >/dev/null
        tee -a "$SCRIPT_DIR/build/rpi-init.sh" <"$module"
    fi
done

chmod a+x "$SCRIPT_DIR/build/rpi-init.sh"
