#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# route traffic for a remote subnet through a dpdk forwarder (l3fwd) on a sender or receiver VM.
# for each --route <dst subnet>,<gateway ip>,<gateway mac>:
#   - find the local interface on the gateway's subnet
#   - ip route replace <dst subnet> via <gateway ip> dev <interface>
#   - add a permanent neighbor entry for the gateway, the forwarder nic is bound to dpdk
#     so nothing answers arp for it.
# the azure side (ip forwarding on the forwarder nics and a subnet route table) is set up
# by deploy/l3fwd.bicep. these routes don't survive a reboot or a netplan re-apply.
#
# usage: setup-l3fwd-route.sh --route <dst cidr>,<gateway ip>,<gateway mac> [--route ...] [--remove]

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
UTIL_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/util"
# shellcheck disable=SC1091
source "$UTIL_DIR/functions.sh"

ROUTES=()
OPTIONS="hr:"
LONGOPTIONS="help,route:,remove"
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    exit 2
fi
eval set -- "$PARSED"
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 --route <dst cidr>,<gateway ip>,<gateway mac> [--route ...] [--remove]"
            echo "  --remove: delete the routes and neighbor entries instead of adding them"
            exit 0
            ;;
        -r|--route)
            [[ "$2" =~ ^[0-9.]+/[0-9]+,[0-9.]+,([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || {
                echo "Error: --route must be <dst cidr>,<gateway ip>,<gateway mac>, got '$2'"
                exit 1
            }
            ROUTES+=( "${2,,}" )
            shift 2
            ;;
        --remove)
            REMOVE="true"
            shift
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
[[ "${#ROUTES[@]}" -gt 0 ]] || { echo "Error: provide at least one --route"; exit 1; }

function interface_for_ip() {
    # print the interface with an ipv4 address on the same subnet as $1
    local ifname cidr
    while read -r _idx ifname _family cidr _rest; do
        [[ "$ifname" == "lo" ]] && continue
        if ip4_in_cidr "$1" "$cidr"; then
            echo "$ifname"
            return 0
        fi
    done < <(ip -o -4 addr show)
    return 1
}

((failed=0))
for route in "${ROUTES[@]}"; do
    IFS=',' read -r dst gw mac <<< "$route"
    dst=$(ip4_network "$dst") || { damn "Error: invalid subnet in --route $route"; ((failed++)); continue; }
    ifname=$(interface_for_ip "$gw") || {
        damn "Error: no local interface on the same subnet as gateway $gw"
        ip -br -4 addr 1>&2
        ((failed++))
        continue
    }
    if [[ -n "$REMOVE" ]]; then
        sudo ip route del "$dst" via "$gw" dev "$ifname" 2> /dev/null
        sudo ip neigh del "$gw" dev "$ifname" 2> /dev/null
        echo "removed route $dst via $gw dev $ifname"
        continue
    fi
    # traffic would bypass the forwarder if this VM can reach the destination subnet directly
    local_dst_if=$(interface_for_ip "${dst%/*}") && \
        damn "Warning: $local_dst_if is on $dst, traffic to $dst may not go through the forwarder"
    sudo ip route replace "$dst" via "$gw" dev "$ifname" \
        && sudo ip neigh replace "$gw" lladdr "$mac" dev "$ifname" nud permanent \
        || { damn "Error: could not add route $dst via $gw ($mac) dev $ifname"; ((failed++)); continue; }
    echo "route $dst via $gw ($mac) dev $ifname"
done

ip route show
ip neigh show nud permanent
exit "$failed"
