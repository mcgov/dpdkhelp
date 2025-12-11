#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

OPTIONS="g:i:h"
LONGOPTIONS="rg:,vm-index:,toggle,help,private-ip:,set:"
# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")

RGNAME=""
TOGGLE=0
PRIVATE_IP_ADDRESS=""
SET_VALUE=0
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    # If getopt has complained about wrong arguments, print the error message and exit
    exit 2
fi

# Use eval to properly handle the parsed options
eval set -- "$PARSED"
export MSYS_NO_PATHCONV=1;
# Process the options
while true; do
    case "$1" in
        -h|--help)
            echo "
Usage: $0 --rg <resource-group-name> -g <resource_group_name> --private-ip <nic private ip> [--set 0|1] [--toggle]"
            exit 0
            ;;
        -g|--rg)
            RGNAME="$2"
            shift 2
            ;;
        --private-ip)
            PRIVATE_IP_ADDRESS="$2"
            shift 2
            ;;
        --toggle)
            TOGGLE=1
            shift
            ;;
        --set)
            SET_VALUE="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1"
            exit 3
            ;;
    esac
done
set -o pipefail;
VM_NAMES=()
while read -r vm_name; do
vm_name="${vm_name//[$'\t\r\n']/}"
VM_NAMES+=("$vm_name");
done < <(az vm list -g "$RGNAME" --query "[].name" -o tsv)

for vm_name in "${VM_NAMES[@]}"; do
    NICS=()
    while read -r nic; do
        nic="${nic//[$'\t\r\n']/}"
        NICS+=("$nic");
    done < <(az vm nic list -g "$RGNAME" --vm-name "$vm_name" --query "[].id" -o tsv)

    for _nic in "${NICS[@]}"; do
        if [[ -z "$_nic" ]]; then
            echo "No NIC found for VM $vm_name in resource group $RGNAME" 1>&2;
            continue;
        fi
        _nic="${_nic//[$'\t\r\n']/}"
         _private_ip=$(az vm nic show  -g "$RGNAME" --vm-name "$vm_name" \
         --nic "$_nic"   \
         --query "ipConfigurations[0].privateIPAddress" -o tsv );
        if [[ -z "$_private_ip" ]]; then
            echo "Could not get private IP for NIC $_nic in VM $vm_name" 1>&2;
            continue;
        fi
        _private_ip="${_private_ip//[$'\t\r\n']/}"
        if [[ "$_private_ip" == "$PRIVATE_IP_ADDRESS" ]]; then
            echo "Found NIC $_nic with private IP $_private_ip for VM $vm_name"
            _nic="$( cut -d '/' -f 9 <<< "$_nic" )"
            if [[ -z "$_nic" ]]; then
                echo "Could not extract NIC name from $_nic" 1>&2;
                continue;
            fi
            if [[ "$TOGGLE" -eq 1 ]]; then
                echo "Toggling accelerated networking for NIC $_nic"
                echo "Disabling accelerated networking for NIC $_nic"
                az network nic update --accelerated-networking 0 -g "$RGNAME" -n "$_nic" \
                || {
                    echo "Failed to disable accelerated networking for NIC $_nic" 1>&2;
                    exit 1;
                }
                sleep 5;
                echo "Enabling accelerated networking for NIC $_nic"
                az network nic update --accelerated-networking 1 -g "$RGNAME" -n "$_nic" \
                || {
                    echo "Failed to enable accelerated networking for NIC $_nic" 1>&2;
                    exit 1;
                }
                exit 0;
            else
                echo "Setting accelerated networking for NIC $_nic to: $SET_VALUE"
                az network nic update --accelerated-networking "$SET_VALUE" -g "$RGNAME" -n "$_nic" \
                || {
                    echo "Failed to set accelerated networking for NIC $_nic" 1>&2;
                    exit 1;
                }
            fi
        fi
    done
done


exit 0