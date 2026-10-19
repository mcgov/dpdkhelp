#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# cache the mac address and ipv4 subnet(s) of each nic before it's bound to a dpdk pmd
# (once bound, the kernel interface and its addresses are gone).
# entries are keyed by mac address, one per line in .dpdkcache/nic_info:
#   <mac> <interface> <ip>/<prefix>[,<ip>/<prefix>...]
# usage: cache-nic-info.sh --device eth1[,eth2]

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# dpdkhelp/.dpdkcache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.dpdkcache"
NIC_INFO="$CACHE_DIR/nic_info"
[[ -d "$CACHE_DIR" ]] || mkdir -p "$CACHE_DIR"

devices=()
OPTIONS="hd:"
LONGOPTIONS="help,device:,interface:"
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    exit 2
fi
eval set -- "$PARSED"
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 --device|--interface eth1[,eth2]"
            exit 0
            ;;
        -d|--device|--interface)
            IFS=',' read -r -a device_list <<< "$2"
            devices+=( "${device_list[@]}" )
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

if [[ "${#devices[@]}" -eq 0 ]]; then
    echo "Error: no devices specified" 1>&2
    exit 1
fi

((failed=0))
touch "$NIC_INFO"
for device in "${devices[@]}"; do
    if [[ ! -e "/sys/class/net/$device/address" ]]; then
        # likely already bound to dpdk, keep any existing entry
        echo "Warning: $device not found, skipping nic info cache for it" 1>&2
        ((failed++))
        continue
    fi
    mac=$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/$device/address")
    cidrs=$(ip -o -4 addr show dev "$device" | awk '{ print $4 }' | paste -sd, -)
    if [[ -z "$cidrs" ]]; then
        echo "Warning: $device ($mac) has no ipv4 address" 1>&2
        cidrs="-"
    fi
    # replace any existing entry for this mac
    grep -v -i "^$mac " "$NIC_INFO" > "$NIC_INFO.tmp"
    echo "$mac $device $cidrs" >> "$NIC_INFO.tmp"
    mv "$NIC_INFO.tmp" "$NIC_INFO"
    echo "cached $device: $mac $cidrs"
done

exit $failed
