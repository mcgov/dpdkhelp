#! /bin/bash

# this script fetches information about the nics on a device
# it makes a best effort to infer some info about the mana setup (or mellanox setup)
# and construct arguments to pass to the EAL arguments of a dpdk application.
# if you hit any issues, contact mamcgove@microsoft.com

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# dpdkhelp/.cache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.cache"
[[ -d "$CACHE_DIR" ]] || mkdir -p "$CACHE_DIR"

# defaults
devices=()

# mana bus addr is always the same on older sizes with a single shared pci device
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

function is_mana_vm () {
    # check for the mana pci device id
    [[ -n $(lspci -d 1414:00ba:0200) ]]
}

# if no devices specified, pick a reasonable default
if [[ "${#devices[@]}" -eq 0 ]]; then
    devices=( "eth1" )
fi

# we're saving a file in the home directory, so don't want to write it as root.
if [[ "$USER" == "root" ]]; then
    echo "Error: don't run as root" 1>&2
    exit 1;
fi

# grab the dpdk vdev info since we're about to mess with the
# interfaces, which will remove the upper eth* interface.
VDEV_ARG_PARTS=()
if is_mana_vm; then
    device_slots=()
    # inventory the device addresses for each device.
    for device in "${devices[@]}"; do
        bus_address=$(basename "$(readlink /sys/class/net/"$device"/lower_*/device)")
        for slot in "${device_slots[@]}"; do
            if [[ "$slot" == "$bus_address" ]]; then
                # already added this slot, skip it.
                continue 2
            fi
        done
        # otherwise add it to the list
        device_slots+=( "$bus_address" )
    done
    # set the MANA argument
    if [[ "${#device_slots[@]}" -eq 1 ]] && [[ "${device_slots[0]}" == "$MANA_BUS_ADDR" ]]; then
        # a single device address with the magic mana address.
        # ovl2 can have a single bus address for multiple VFs including the ssh interface.
        # so if a single address is available, pass a --vdev argument to specify an explicit mac
        # address for the pmd. 
        VDEV_ARG="$MANA_BUS_ADDR"
        for device in "${devices[@]}"; do
            # mana vdev argument for dpdk follows the form:
            # --vdev={mana_pci_bus_addr}(,mac=xx:xx:xx:xx:xx)+
            MANA_MAC="$(cat /sys/class/net/"$device"/address)"
            VDEV_ARG+=",mac=$MANA_MAC"
        done
        VDEV_ARG="--vdev=$VDEV_ARG"
    elif [[ "${#device_slots[@]}" -gt 0 ]]; then
        # this case is easier, indicating ovl3 or mlnx with mutliple vfs. We can just allow the device addresses.
        for slot in "${device_slots[@]}"; do
        # NOTE: older dpdks < 20.11 used -w instead of -a.
            VDEV_ARG_PARTS+=( -a "$slot" )
        done
        VDEV_ARG="${VDEV_ARG_PARTS[*]}"
    else
        # we really shouldn't be able to get here on a fresh VM; is_mana checks for a device address
        echo "Error: found no device addresses for devices: ${devices[*]}" 1>&2
        exit 1
    fi
else
    # for mellanox, it's way easier. just block the eth0 interface.
    bus_address=$(basename "$(readlink /sys/class/net/eth0/lower_*/device)")
    if [[ -z "$bus_address" ]]; then
        echo "Could not find eth0 pci address" 1>&2;
        exit 1;
    fi
    VDEV_ARG="-b $bus_address"
fi

# save the vdev argument to a file
echo -n "$VDEV_ARG" > "$CACHE_DIR"/vdev_args

# now, load the uio_hv_generic driver if needed...
[[ -d /sys/bus/vmbus/drivers/uio_hv_generic ]] || {
    # shellcheck disable=SC2015
    sudo modprobe uio_hv_generic \
    && echo "f8615163-df3e-46c5-913f-f2d2f965ed0e" \
    | sudo tee "/sys/bus/vmbus/drivers/uio_hv_generic/new_id" || {
        echo "Could not load uio_hv_generic module!" 1>&2;
        exit 1;
    }
}
# and bind the eth interfaces to it.
for device in "${devices[@]}"; do
    # get the netvsc guid for the interface
    ETH_GUID=$(basename "$(readlink /sys/class/net/"$device"/device)")
    if [[ -z "$ETH_GUID" ]]; then
        echo "Could not grab netvsc guid for $device!" 1>&2;
        exit 1
    fi

    # shellcheck disable=SC2015
    sudo ip link set "$device" down \
    && echo "$ETH_GUID" | sudo tee /sys/bus/vmbus/drivers/hv_netvsc/unbind \
    && echo "$ETH_GUID" | sudo tee /sys/bus/vmbus/drivers/uio_hv_generic/bind \
    || {
        echo "Could not setup netvsc pmd for $device!"  1>&2;
        exit 1;
    }
    echo "$ETH_GUID" >> "$CACHE_DIR"/eth_guids
done

# and echo the vdev arg afterwards.
echo "$VDEV_ARG"

exit 0;