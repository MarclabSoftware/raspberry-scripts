#!/usr/bin/env bash

enableNanoSyntaxHighlighting() {
    echo -e "\n\nEnabling Nano Syntax highlighting"

    if isVarEmpty "$CONFIG_USER"; then
        echo -e "\nMissing CONFIG_USER, please enter the normal user name and press enter\n"
        read -r
        CONFIG_USER="$REPLY"
    fi

    if ! isNormalUser "$CONFIG_USER"; then
        echo >&2 -e "\nCONFIG_USER problem, it must be set, it must be a normal user, it must exists"
        return 1
    fi

    if isVarEmpty "$HOME_USER_D"; then
        HOME_USER_D=$(sudo -u "$CONFIG_USER" sh -c 'echo $HOME')
    fi

    if isVarEmpty "$HOME_ROOT_D"; then
        HOME_ROOT_D=$(sudo -u root sh -c 'echo $HOME')
    fi

    local nano_conf_f=".nanorc"
    local nano_conf_user_f="$HOME_USER_D/$nano_conf_f"
    local nano_conf_root_f="$HOME_ROOT_D/$nano_conf_f"

    if [ ! -f "$nano_conf_root_f" ] || ! grep -q 'include "/usr/share/nano/\*.nanorc' "$nano_conf_root_f"; then
        echo -e 'include "/usr/share/nano/*.nanorc"\nset linenumbers' | tee -a "$nano_conf_root_f" >/dev/null
    else
        echo "$nano_conf_root_f already configured"
    fi

    if [ ! -f "$nano_conf_user_f" ] || ! grep -q 'include "/usr/share/nano/\*.nanorc' "$nano_conf_user_f"; then
        echo -e 'include "/usr/share/nano/*.nanorc"\nset linenumbers' | sudo -u "$CONFIG_USER" tee -a "$nano_conf_user_f" >/dev/null
    else
        echo "$nano_conf_user_f already configured"
    fi
    echo -e "\nNano Syntax highlighting enabled"
    return 0
}

# Check if script is executed or sourced
(return 0 2>/dev/null) && sourced=true || sourced=false

if [ "$sourced" = false ]; then
    SCRIPT_D=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    # Source needed files
    . "$SCRIPT_D/init.conf"
    . "$SCRIPT_D/utils.sh"
    checkSU || exit 1
    enableNanoSyntaxHighlighting
    exit $?
fi
