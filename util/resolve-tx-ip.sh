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

PORTS_ARGS=()
[[ -n "$DEVNAME_BIN" ]] && PORTS_ARGS+=( --devname "$DEVNAME_BIN" )
[[ -n "$DEVNAME_OUTPUT_FILE" ]] && PORTS_ARGS+=( --devname-output "$DEVNAME_OUTPUT_FILE" )
PORT_LIST=$("$SCRIPT_DIR/dpdk-ports.sh" "${PORTS_ARGS[@]}" -- "${EAL_ARGS[@]}") || exit 1

((resolved=0))
while read -r port mac; do
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
done <<< "$PORT_LIST"

if [[ "$resolved" -eq 0 ]]; then
    damn "Error: could not resolve any ports. dpdk ports (port mac):"
    damn "$PORT_LIST"
    exit 1
fi
exit 0
