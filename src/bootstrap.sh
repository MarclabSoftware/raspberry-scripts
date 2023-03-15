#!/usr/bin/env bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

echo "Prepare scripts dir"
rm -rf "$SCRIPT_DIR/tmp-scripts"
mkdir -p "$SCRIPT_DIR/tmp-scripts"

echo "Split file into modules"
csplit -z -f "$SCRIPT_DIR/tmp-scripts/part-" -b %02d.module "${0}" /#\ {{.*}}/ '{*}' >/dev/null
rm "$SCRIPT_DIR/tmp-scripts/part-00.module"
chmod -R a+x "$SCRIPT_DIR"/tmp-scripts/*.module

for module in "$SCRIPT_DIR"/tmp-scripts/*.module; do
    moduleRelPath=$(head -n 1 "$module" | grep -oP "(?<={{).*(?=}})")
    moduleDir=$(dirname "$moduleRelPath")
    moduleName=$(basename "$moduleRelPath")
    echo "Rename '$module' into './tmp-scripts/$moduleDir/$moduleName'"
    sed -i -e "1,1d" "$module"
    mkdir -p "$SCRIPT_DIR/tmp-scripts/$moduleDir"
    mv "$module" "$SCRIPT_DIR/tmp-scripts/$moduleDir/$moduleName"
done

sudo "$SCRIPT_DIR/tmp-scripts/scripts/init_script.sh"

exit 0 # Important for later merge/split, do not remove