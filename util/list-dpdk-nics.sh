#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# list the synthetic (hv_netvsc) nics on the VM that can be used for dpdk, comma separated.
# eth0 is excluded by default since it's usually the ssh/management interface.
# accelerated networking VFs (mana/mlx) are not listed, the setup scripts find them from the netvsc nic.
# usage: list-dpdk-nics.sh [--exclude eth0[,eth1]]

EXCLUDE="eth0"
OPTIONS="h"
LONGOPTIONS="help,exclude:"
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    exit 2
fi
eval set -- "$PARSED"
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [--exclude eth0[,eth1]]"
            exit 0
            ;;
        --exclude)
            EXCLUDE="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "unrecognized argument: $1"
            exit 1
            ;;
    esac
done

nics=()
for path in /sys/class/net/*; do
    name=$(basename "$path")
    [[ ",$EXCLUDE," == *",$name,"* ]] && continue
    driver=$(basename "$(readlink -f "$path/device/driver" 2> /dev/null)" 2> /dev/null)
    [[ "$driver" == "hv_netvsc" ]] || continue
    nics+=( "$name" )
done

if [[ "${#nics[@]}" -eq 0 ]]; then
    echo "Error: no netvsc nics found (excluding $EXCLUDE). Are they already bound to dpdk?" 1>&2
    exit 1
fi
(IFS=,; echo "${nics[*]}")
