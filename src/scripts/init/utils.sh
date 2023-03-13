#!/usr/bin/env bash

# Press any key to continue
paktc() {
    echo
    read -n 1 -s -r -p "Press any key to continue"
    echo
}

# Check if running as root
checkSU() {
    if [ ! "${EUID:-$(id -u)}" -eq 0 ]; then
        echo "Please run as root"
        return 1
    fi
    return 0
}

# Check if a configuration var exists via indirection
# The argument to use is the name of the var, not the var itself
# If it exists and its value is true or false: returns the value (true=0 false=1)
# If it doesn't exist, or if it's value is 'ask': configures it on the fly as boolean and returns the result
# If it exists  and its value is any other value: returns >1 values as error
checkConfig() {
    if [ $# -eq 0 ]; then
        echo "${BASH_SOURCE[$i + 1]}:${BASH_LINENO[$i]} - ${FUNCNAME[$i]}: no arguments provided"
        paktc
        return 2
    fi
    if [ -z ${!1+x} ] || [ "${!1}" = "ask" ]; then
        read -p "Do you want to apply init config for ${1}? Y/N: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            return 0
        else
            return 1
        fi
    elif [ "${!1}" = true ]; then
        return 0
    elif [ "${!1}" = false ]; then
        return 1
    else
        echo -e "\n${BASH_SOURCE[$i + 1]}:${BASH_LINENO[$i]} - ${FUNCNAME[$i]}: config error for ${1}: wrong value, current value: '${!1}'\nPossible values are true,false,ask"
        paktc
        return 3
    fi
}

# Check if a command exists
checkCommand() {
    if ! command -v "${1}" &>/dev/null; then
        echo "${1} command not found"
        return 1
    fi
    return 0
}

# Check if a var is set, bash only
isVarSet() {
    declare -p "$1" &>/dev/null
}

# Return type of a variable, input arg is var name, bash only
varType() {
    if ! isVarSet "$1"; then
        echo "UNSET"
        return 1
    fi

    local var
    var=$(declare -p "$1" 2>/dev/null)
    local reg='^declare -n [^=]+=\"([^\"]+)\"$'
    while [[ $var =~ $reg ]]; do
        var=$(declare -p "${BASH_REMATCH[1]}")
    done

    case "${var#declare -}" in
    a*)
        echo "ARRAY"
        ;;
    A*)
        echo "HASH"
        ;;
    i*)
        echo "INT"
        ;;
    x*)
        echo "EXPORT"
        ;;
    *)
        echo "OTHER"
        ;;
    esac
    return 0
}

# Check if a var is an array, input arg is var name, bash only
isArray() {
    if (varType "$1" | grep -q "ARRAY"); then
        return 0
    fi
    return 1
}
