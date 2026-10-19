#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# resolve per-port testpmd --tx-ip values ([port:]src,dst) from a list of destination ips.
# uses dpdk-devname (github.com/mcgov/devname) to map dpdk port ids to mac addresses,
# then the nic info cached by cache-nic-info.sh to find the source ip of each port.
# the destination for a port is the first --dst ip in the same subnet as its source ip.
#
# usage: resolve-tx-ip.sh --dst <ip>[,<ip>...] [--devname <path>] [-- <eal args>]
#   eal args default to the cached vdev_arg, these must match the args used for testpmd
#   so the port ids line up.
# prints one <port>:<src>,<dst> per line.

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# dpdkhelp/.dpdkcache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.dpdkcache"
NIC_INFO="$CACHE_DIR/nic_info"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/functions.sh"

dst_ips=()
DEVNAME_BIN=""
DEVNAME_OUTPUT_FILE=""
OPTIONS="h"
LONGOPTIONS="help,dst:,devname:,devname-output:"
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    exit 2
fi
eval set -- "$PARSED"
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 --dst <ip>[,<ip>...] [--devname <path>] [--devname-output <file>] [-- <eal args>]"
            echo "  --devname-output: parse saved dpdk-devname output instead of running it"
            exit 0
            ;;
        --dst)
            IFS=',' read -r -a ip_list <<< "$2"
            dst_ips+=( "${ip_list[@]}" )
            shift 2
            ;;
        --devname)
            DEVNAME_BIN="$2"
            shift 2
            ;;
        --devname-output)
            DEVNAME_OUTPUT_FILE="$2"
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
EAL_ARGS=( "$@" )

if [[ "${#dst_ips[@]}" -eq 0 ]]; then
    damn "Error: no --dst addresses provided"
    exit 1
fi
for dst in "${dst_ips[@]}"; do
    ip4_to_int "$dst" > /dev/null || { damn "Error: invalid ipv4 address '$dst'"; exit 1; }
done
[[ -s "$NIC_INFO" ]] || {
    damn "Error: no nic info cached at $NIC_INFO. Run setup/setup-netvsc-pmd.sh or setup/setup-mana-pmd.sh first."
    exit 1
}

if [[ -n "$DEVNAME_OUTPUT_FILE" ]]; then
    DEVNAME_OUTPUT=$(cat "$DEVNAME_OUTPUT_FILE") || exit 1
else
    if [[ -z "$DEVNAME_BIN" ]]; then
        # install-dpdk.sh builds it under the installed examples (only added to PATH in .bashrc),
        # a meson build with -Dexamples=devname leaves it in the dpdk build dir
        for candidate in "$(command -v dpdk-devname)" "$(command -v devname)" \
            /usr/local/bin/dpdk-devname \
            /usr/local/share/dpdk/examples/devname/build/devname \
            "$HOME/dpdk/build/examples/dpdk-devname"; do
            [[ -n "$candidate" ]] && [[ -x "$candidate" ]] && { DEVNAME_BIN="$candidate"; break; }
        done
    fi
    [[ -n "$DEVNAME_BIN" ]] && [[ -x "$DEVNAME_BIN" ]] || {
        damn "Error: dpdk-devname not found, install from github.com/mcgov/devname or pass --devname"
        exit 1
    }
    if [[ "${#EAL_ARGS[@]}" -eq 0 ]] && [[ -f "$CACHE_DIR/vdev_arg" ]]; then
        # vdev_arg is a space separated arg string, split it intentionally
        read -r -a EAL_ARGS < "$CACHE_DIR/vdev_arg"
    fi
    DEVNAME_OUTPUT=$(sudo "$DEVNAME_BIN" "${EAL_ARGS[@]}" 2>&1)
fi

((resolved=0))
while read -r line; do
    port=""; owner_id=""; mac=""
    for field in $line; do
        case "$field" in
            port=*) port="${field#port=}" ;;
            owner_id=*) owner_id="${field#owner_id=}" ;;
            macaddr=*) mac="${field#macaddr=}" ;;
        esac
    done
    # owned ports (ex: mana ports under a netvsc port) aren't used for forwarding by testpmd
    if [[ -n "$owner_id" ]] && [[ $((owner_id)) -ne 0 ]]; then
        continue
    fi
    mac="${mac,,}"
    cidrs=$(awk -v mac="$mac" 'tolower($1) == mac { print $3 }' "$NIC_INFO")
    if [[ -z "$cidrs" ]] || [[ "$cidrs" == "-" ]]; then
        damn "Warning: no cached ip for port $port ($mac), skipping"
        continue
    fi
    match=""
    IFS=',' read -r -a cidr_list <<< "$cidrs"
    for cidr in "${cidr_list[@]}"; do
        for dst in "${dst_ips[@]}"; do
            if ip4_in_cidr "$dst" "$cidr"; then
                match="$port:${cidr%/*},$dst"
                break 2
            fi
        done
    done
    if [[ -z "$match" ]]; then
        damn "Warning: no --dst address in subnet(s) $cidrs for port $port ($mac), skipping"
        continue
    fi
    echo "$match"
    ((resolved++))
done < <(grep 'dpdk-devname found port=' <<< "$DEVNAME_OUTPUT")

if [[ "$resolved" -eq 0 ]]; then
    damn "Error: could not resolve any ports. dpdk-devname output:"
    damn "$DEVNAME_OUTPUT"
    exit 1
fi
exit 0
