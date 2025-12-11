#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# dpdkhelp/.dpdkcache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.dpdkcache"
[[ -d "$CACHE_DIR" ]] || mkdir -p "$CACHE_DIR"

devices="eth1"
pmd="netvsc"

# flags
OPTIONS="d:p:h"
LONGOPTIONS="help,pmd:,device:"

# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    # If getopt has complained about wrong arguments, print the error message and exit
    exit 2
fi
eval set -- "$PARSED"
# Process the options
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [--device|--interface eth1[,eth2]] [--help]"
            exit 0
            ;;
        -d|--device|--interface)
            # allow comma seperated or multiple instances of -d arg
            devices="$2"
            shift 2
            ;;
        --pmd)
            pmd="$2"
            shift 2
            ;;
        --)
            break
            ;;
        *)
            echo "unrecognized argument: $1"
            exit 1
            ;;
    esac
done

"$SCRIPT_DIR"/enable-hugepages.sh -c 16 -s 1G --node 0 && "$SCRIPT_DIR"/setup-"$pmd"-pmd.sh --device "$devices"

exit $?