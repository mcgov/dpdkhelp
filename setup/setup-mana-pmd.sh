#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# dpdkhelp/.dpdkcache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.dpdkcache"
[[ -d "$CACHE_DIR" ]] || mkdir -p "$CACHE_DIR"

# defaults
devices=()
((failed=0))
# mana bus addr is always the same on older sizes with a single shared pci device
# keep this address to compare.
MANA_BUS_ADDR="7870:00:00.0"

# flags
OPTIONS="hd:"
LONGOPTIONS="help,device:,interface:"

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
            if [[ "$2" == *,* ]]; then
                IFS=',' read -r -a device_list <<< "$2"
                for device in "${device_list[@]}"; do
                    devices+=( "$device" )
                done
            else
                devices+=( "$2" )
            fi
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


vdev_arg=""
# coalesce the device pci slot and mac address associations
# a pci slot can be associated with more than one if it's using vports
declare -A addresses;

# for each device requested by the user
for device in "${devices[@]}"; do
    # find if there's an associated puppet device
    puppet=$(ip -br link show master "$device" 2> /dev/null | awk '{ print $1}');
    # get the device mac (master and puppet should share an address if using vports)
    address=$(cat "/sys/class/net/$device/address")
    # get the puppet or master pci slot
    if [[ -z "$puppet" ]]; then
        pci_slot=$(basename "$(readlink -f "/sys/class/net/$device/device")");
    else
        pci_slot=$(basename "$(readlink -f "/sys/class/net/$puppet/device")");
    fi
    [[ -z "$pci_slot" ]] && { \
        echo "Could not find pci slot for $device!" 1>&2;\
        ((failed++));\
        continue;
    }
    # get the address, appending if there is another one already associated w it
    if [[ -z "${addresses["$pci_slot"]}" ]]; then
        addresses["$pci_slot"]="mac=$address"
    else
        addresses["$pci_slot"]+=",mac=$address"
    fi
done

for pci_slot in "${!addresses[@]}"; do
    # if there's more than one interface, allowlist them
    [[ "${#addresses[@]}" -gt 1 ]] && vdev_arg+="-a $pci_slot";
    # and add the mana pmd arg
    vdev_arg+=" --vdev=$pci_slot,${addresses[$pci_slot]}"
done

# cache the mac and ip subnet of each nic before they're taken down
if [[ "${#devices[@]}" -gt 0 ]]; then
    "$(dirname "$SCRIPT_DIR")/util/cache-nic-info.sh" --device "$(IFS=,; echo "${devices[*]}")" \
        || echo "Warning: could not cache nic info for all devices" 1>&2
fi

for device in "${devices[@]}"; do
    sudo ip link set "$device" down || { 
        echo "Could not set device $device down!" 1>&2;
        ((failed++));
    }
done

echo "$vdev_arg" | tee "$CACHE_DIR/vdev_arg" || { 
    echo "Could not write vdev arg to ${CACHE_DIR}/vdev_arg" 1>&2 ;
    ((failed++));
}

exit $failed