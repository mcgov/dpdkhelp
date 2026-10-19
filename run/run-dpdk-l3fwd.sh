#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# run dpdk-l3fwd on a forwarder VM (an NVA between a sender and receiver on different subnets).
# run setup/setup-netvsc-pmd.sh or setup/setup-mana-pmd.sh on the data nics first, the vdev args
# and the nic info (mac, subnet) cached by those scripts are used to build the l3fwd config.
#
# each dpdk port (resolved with dpdk-devname) gets:
#   - an lpm rule sending traffic for the port's subnet out of that port
#   - an --eth-dest for the --peer on that port's subnet (the sender/receiver nic mac)
# see https://doc.dpdk.org/guides/sample_app_ug/l3_forward.html
#
# usage: run-dpdk-l3fwd.sh --peer <ip>,<mac> [--peer <ip>,<mac>]... [--queues <n>] [--core-list 1,2,3,4]
#            [--l3fwd <path>] [--dry-run] [-- <extra l3fwd app args>]
# l3fwd runs until it's interrupted (SIGINT), use timeout -s INT to limit the run.

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
UTIL_DIR="$(dirname "$SCRIPT_DIR")/util"
# dpdkhelp/.dpdkcache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.dpdkcache"
NIC_INFO="$CACHE_DIR/nic_info"
# shellcheck disable=SC1091
source "$UTIL_DIR/functions.sh"

PEERS=()
QUEUE_COUNT=""
CORE_LIST=""
L3FWD_BIN="${L3FWD_BIN:-}"
PORTS_ARGS=()
OPTIONS="hq:l:"
LONGOPTIONS="help,peer:,queues:,core-list:,l3fwd:,dry-run,devname-output:"
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    exit 2
fi
eval set -- "$PARSED"
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 --peer <ip>,<mac> [--peer <ip>,<mac>]... [-q|--queues <n>] [-l|--core-list 1,2,3,4]"
            echo "          [--l3fwd <path>] [--dry-run] [-- <extra l3fwd app args>]"
            echo "  --peer: next hop (sender/receiver nic) ip and mac, matched to a dpdk port by subnet"
            echo "  --queues: queues per port, defaults to a count based on the number of cpus"
            echo "  --core-list: comma separated lcores, defaults to 1..N for the cores needed"
            echo "  --dry-run: write the rules files and print the l3fwd command without running it"
            exit 0
            ;;
        --peer)
            [[ "$2" =~ ^[0-9.]+,([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || {
                echo "Error: --peer must be <ipv4>,<mac>, got '$2'"
                exit 1
            }
            PEERS+=( "${2,,}" )
            shift 2
            ;;
        -q|--queues)
            [[ "$2" =~ ^[1-9][0-9]*$ ]] || { echo "Error: --queues must be a number"; exit 1; }
            QUEUE_COUNT="$2"
            shift 2
            ;;
        -l|--core-list)
            [[ "$2" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "Error: --core-list must be comma separated core ids"; exit 1; }
            CORE_LIST="$2"
            shift 2
            ;;
        --l3fwd)
            L3FWD_BIN="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --devname-output)
            # testing: parse saved dpdk-devname output
            PORTS_ARGS+=( --devname-output "$2" )
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Error: unrecognized option $1"
            exit 1
            ;;
    esac
done
EXTRA_ARGS=( "$@" )

[[ "${#PEERS[@]}" -gt 0 ]] || { echo "Error: provide at least one --peer <ip>,<mac>"; exit 1; }
[[ -f "$CACHE_DIR/vdev_arg" ]] && [[ -s "$NIC_INFO" ]] || {
    echo "Error: no vdev_arg or nic_info cached in $CACHE_DIR. Run setup/setup-netvsc-pmd.sh --device eth1,eth2 first."
    exit 1
}
VDEV_ARG=$(cat "$CACHE_DIR/vdev_arg")
echo "eal args: $VDEV_ARG"
echo "nic_info:"
cat "$NIC_INFO"
echo "peers: ${PEERS[*]}"

if [[ -z "$L3FWD_BIN" ]]; then
    # install-dpdk.sh builds the example with make under the installed examples dir,
    # a meson build with -Dexamples=l3fwd leaves it in the dpdk build dir
    for candidate in "$(command -v dpdk-l3fwd)" \
        /usr/local/share/dpdk/examples/l3fwd/build/l3fwd \
        "$HOME/dpdk/build/examples/dpdk-l3fwd"; do
        [[ -n "$candidate" ]] && [[ -x "$candidate" ]] && { L3FWD_BIN="$candidate"; break; }
    done
fi
[[ -n "$L3FWD_BIN" ]] && { [[ -x "$L3FWD_BIN" ]] || [[ -n "$DRY_RUN" ]]; } || {
    echo "Error: dpdk l3fwd example not found, build dpdk with install/dpdk/install-dpdk.sh or pass --l3fwd"
    exit 1
}

# shellcheck disable=SC2086
PORT_LIST=$("$UTIL_DIR/dpdk-ports.sh" "${PORTS_ARGS[@]}" -- $VDEV_ARG) || exit 1
echo "dpdk ports (port mac):"
echo "$PORT_LIST"

RULES_V4="$CACHE_DIR/l3fwd_rules_v4"
RULES_V6="$CACHE_DIR/l3fwd_rules_v6"
PORTS=()
ETH_DEST_ARGS=()
: > "$RULES_V4.tmp"
: > "$RULES_V6.tmp"
while read -r port mac; do
    cidrs=$(awk -v mac="$mac" 'tolower($1) == mac { print $3 }' "$NIC_INFO")
    if [[ -z "$cidrs" ]] || [[ "$cidrs" == "-" ]]; then
        damn "Warning: no cached ip for port $port ($mac), not forwarding on it"
        continue
    fi
    peer_match=""
    IFS=',' read -r -a cidr_list <<< "$cidrs"
    for cidr in "${cidr_list[@]}"; do
        for peer in "${PEERS[@]}"; do
            if ip4_in_cidr "${peer%,*}" "$cidr"; then
                peer_match="$peer"
                port_cidr="$cidr"
                break 2
            fi
        done
    done
    if [[ -z "$peer_match" ]]; then
        damn "Warning: no --peer in subnet(s) $cidrs for port $port ($mac), not forwarding on it"
        continue
    fi
    network=$(ip4_network "$port_cidr") || { damn "Error: bad cidr $port_cidr for port $port"; exit 1; }
    echo "port $port ($mac) $port_cidr -> peer ${peer_match%,*} (${peer_match#*,})"
    # traffic for this port's subnet goes out of this port, to the peer's mac
    echo "R $network $port" >> "$RULES_V4.tmp"
    # ipv6 isn't used in azure, but l3fwd requires valid ipv6 rules too
    echo "R $(ip4_to_ipv6_lpm "${network%/*}") $port" >> "$RULES_V6.tmp"
    ETH_DEST_ARGS+=( "--eth-dest=$port,${peer_match#*,}" )
    PORTS+=( "$port" )
done <<< "$PORT_LIST"
mv "$RULES_V4.tmp" "$RULES_V4"
mv "$RULES_V6.tmp" "$RULES_V6"

[[ "${#PORTS[@]}" -ge 2 ]] || {
    echo "Error: need at least 2 dpdk ports with a --peer on their subnet to forward, found ${#PORTS[@]}"
    echo "dpdk ports (port mac):"
    echo "$PORT_LIST"
    exit 1
}

IS_MANA=""
is_mana_vm && IS_MANA="true"
# mana: queue N of a pair of ports share one core (it rejects configs with more cores than queues),
# others: one core per port queue. (same as the LISA l3fwd test)
PORTS_PER_CORE=1
[[ -n "$IS_MANA" ]] && PORTS_PER_CORE=2
PORT_GROUPS=$(( (${#PORTS[@]} + PORTS_PER_CORE - 1) / PORTS_PER_CORE ))

THREADS=$(nproc)
if [[ -n "$CORE_LIST" ]]; then
    IFS=',' read -r -a AVAILABLE_CORES <<< "$CORE_LIST"
else
    # leave core 0 for the os
    mapfile -t AVAILABLE_CORES < <(seq 1 $((THREADS - 1)))
fi
if [[ -z "$QUEUE_COUNT" ]]; then
    # queue count by vm size, from the LISA l3fwd test
    if ((THREADS <= 8)); then QUEUE_COUNT=2
    elif ((THREADS <= 16)); then QUEUE_COUNT=4
    elif ((THREADS <= 32)); then QUEUE_COUNT=8
    else QUEUE_COUNT=16
    fi
    [[ -n "$IS_MANA" ]] && QUEUE_COUNT=$((QUEUE_COUNT * 2))
    # scale down to fit the cores we have
    while ((QUEUE_COUNT > 1 && QUEUE_COUNT * PORT_GROUPS > ${#AVAILABLE_CORES[@]})); do
        QUEUE_COUNT=$((QUEUE_COUNT / 2))
    done
fi
CORES_NEEDED=$((QUEUE_COUNT * PORT_GROUPS))
((CORES_NEEDED <= ${#AVAILABLE_CORES[@]})) || {
    echo "Error: $QUEUE_COUNT queues on ${#PORTS[@]} ports needs $CORES_NEEDED cores, only ${#AVAILABLE_CORES[@]} available"
    exit 1
}

# (port,queue,lcore) tuples
CONFIG=()
USED_CORES=()
((core_index=0))
for ((q = 0; q < QUEUE_COUNT; q++)); do
    for ((p = 0; p < ${#PORTS[@]}; p++)); do
        if ((p % PORTS_PER_CORE == 0)); then
            core="${AVAILABLE_CORES[$core_index]}"
            USED_CORES+=( "$core" )
            ((core_index++))
        fi
        CONFIG+=( "(${PORTS[$p]},$q,$core)" )
    done
done

PORTMASK=0
for port in "${PORTS[@]}"; do
    PORTMASK=$(( PORTMASK | (1 << port) ))
done

# mana doesn't support promiscuous mode
PROMISC_ARG="-P"
[[ -n "$IS_MANA" ]] && PROMISC_ARG=""

# prefer the '-l 1,2,3' form over '-l 1-3' to avoid a dpdk bug
JOINED_CORES=$(IFS=,; echo "${USED_CORES[*]}")
JOINED_CONFIG=$(IFS=,; echo "${CONFIG[*]}")
RUN_L3FWD_CMD="sudo $L3FWD_BIN $VDEV_ARG -l $JOINED_CORES -- $PROMISC_ARG -p $(printf '0x%x' "$PORTMASK")"
RUN_L3FWD_CMD+=" --lookup=lpm --config=\"$JOINED_CONFIG\" ${ETH_DEST_ARGS[*]}"
RUN_L3FWD_CMD+=" --rule_ipv4=$RULES_V4 --rule_ipv6=$RULES_V6 --mode=poll --parse-ptype ${EXTRA_ARGS[*]}"

echo "rules_v4:"
cat "$RULES_V4"
echo "Note: $QUEUE_COUNT queue(s) per port on ${#PORTS[@]} ports, lcores $JOINED_CORES"

# write the command out to a file and run that, like run-dpdk-testpmd.sh
{
    echo "#! /bin/sh"
    echo "pkg-config --modversion libdpdk"
    echo "uname -r"
    echo "$RUN_L3FWD_CMD 2>&1 | tee last-dpdk-l3fwd-log.txt"
    echo 'exit $?'
} > ./rerun-dpdk-l3fwd.sh
chmod +x ./rerun-dpdk-l3fwd.sh
echo "$RUN_L3FWD_CMD"

[[ -n "$DRY_RUN" ]] && exit 0

sudo ufw disable || true
# NOTE: don't remove this leading period
#shellcheck disable=SC1091
. ./rerun-dpdk-l3fwd.sh 2>&1
exit $?
