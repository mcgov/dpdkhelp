#! /bin/bash
# author: mamcgove @microsoft.com

# run a packet-per-second test with dpdk-testpmd.
# this script sets up a test using the netvsc pmd
# you can use the same script to start a sender and receiver on two VMs
# `pps-dpdk-testpmd.sh rxonly` on the receiver
# `pps-dpdk-testpmd.sh txonly $SENDER_IP,$RECEIVER_IP` on the sender
#
# set --queue and --core-list and --nb-cores arguments to tune performance,
# defaults will be picked otherwise and may not be optimal.

OPTIONS="hm:t:"
LONGOPTIONS="mode:,tx-ip:,help,timeout:,queues:,core-list:,nb-cores:,asan"
# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    # If getopt has complained about wrong arguments, print the error message and exit
    exit 2
fi

# Use eval to properly handle the parsed options
eval set -- "$PARSED"
# Process the options
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [-m|--mode <rxonly|txonly>] [--tx-ip <sender_ip>,<receiver_ip>] [-t|--timeout <int>]"
            exit 0
            ;;
        -m|--mode)
            export FWDMODE="$2";
            if [[ "$FWDMODE" != "rxonly" ]] && [[ "$FWDMODE" != "txonly" ]]; then
                echo "Error: mode must be rxonly or txonly"
                exit 1
            fi
            shift 2
            ;;
        --tx-ip)
            IFS=',' read -r -a IP_ARGS <<< "$2"
            SEND_IP="${IP_ARGS[0]}"
            RECV_IP="${IP_ARGS[1]}"
            if [[ -z "$SEND_IP" ]] || [[ -z "$RECV_IP" ]]; then
                echo "Error: must provide both sender and receiver IP addresses"
                exit 1
            fi
            shift 2
            ;;
        --queues)
            QUEUE_COUNT="$2"
            shift 2
            ;;
        --core-list)
            CORE_LIST="$2"
            shift 2
            ;;
        --nb-cores)
            FWD_CORES="$2"
            shift 2
            ;;
        --asan)
            USE_ASAN_OPTIONS="ASAN_OPTIONS=detect_leaks=false LD_PRELOAD=$(find /usr/lib -name libasan.so)"
            shift
            ;;
        --timeout|-t)
            TIMEOUT="$2"
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

# path helpers
SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# dpdkhelp/.cache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.cache"
[[ -d "$CACHE_DIR" ]] && [[ -f "$CACHE_DIR/vdev_args" ]] || {
    echo "Error: no vdev_args file was found cached in $CACHE_DIR. Run setup/setup-netvsc-pmd --device eth1[,eth2] first.";
    exit 1; 
}

if [[ "$FWDMODE" == "txonly" ]]; then
    # txonly mode requires sender and receiver IP addresses
    # shellcheck disable=SC2015
    [[ -n "$SEND_IP" ]] && [[ -n "$RECV_IP" ]] ||  {
        echo "Error: txonly mode requires sender and receiver IP addresses"
        exit 1;
    }
fi

## Parse Arguments

# Assuming use of eth1 for DPDK in this demo

if [[ -z "$TIMEOUT" ]]; then
    TIMEOUT=120
fi

if [[ "$FWDMODE" == "rxonly" ]] || [[ -z "$SEND_IP" ]] || [[ -z "$RECV_IP" ]]; then
    SENDER_IP_ARG=""
else
    SENDER_IP_ARG="--tx-ip=\"$SEND_IP,$RECV_IP\""
fi

sudo ufw disable || true;

# if queue count and core list (or just nb-cores) weren't provided, set defaults
[[ -z "$FWD_CORES" ]] && FWD_CORES=$(element_count_cs "$CORE_LIST")
[[ -n "$QUEUE_COUNT" ]] && [[ -n "$CORE_LIST" ]] || { 
    case "$FWDMODE" in
        "txonly")
            if is_mana_vm; then
                QUEUE_COUNT=4
                FWD_CORES=8
            else
                QUEUE_COUNT=8
                FWD_CORES=8
            fi
            ;;
        "rxonly")
            if is_mana_vm; then
                QUEUE_COUNT=8
                FWD_CORES=8
            else
                QUEUE_COUNT=8
                FWD_CORES=8
            fi
            ;;
    esac
    # this logic sucks. I really don't know what the best way to handle this is.
    # defaults are hard. best practice, use the queue and core-list flags

    # number of cores on the VM on node 0
    LAST_CORE_NUMA0=$(lscpu | grep --fixed-strings 'NUMA node0 CPU(s):' | cut -f 2 -d ':' | xargs | cut -d '-' -f2)
    ((LAST_CORE=FWD_CORES*2))
    ((LAST_CORE=LAST_CORE+4))

    [[ "$LAST_CORE" -le $LAST_CORE_NUMA0 ]] || {
        echo "Error: use a size with $LAST_CORE or more cores on numa 0."
        exit 1;
    }
    # use up the numa node if more cores are available
    [[ "$LAST_CORE_NUMA0" -gt "$LAST_CORE" ]] && LAST_CORE="$LAST_CORE_NUMA0";

    # core list arg
    is_mana_vm \
    && {
        CORE_LIST=$( range_cs 2 "$LAST_CORE" 2 );
    } \
    || CORE_LIST="2-$LAST_CORE"
    
    echo "Note: set queue count to $QUEUE_COUNT with cores $CORE_LIST as default";
}

# fetch the vdev args from the cache
VDEV_ARG=$(cat "$CACHE_DIR/vdev_args")

is_mana_vm \
&& DESCRIPTOR_COUNT=256 \
|| DESCRIPTOR_COUNT=""

# log the testpmd command for future re-runs
# --log-level=mana,debug --log-level=netvsc,debug --log-level=vmbus,debug
RUN_DPDK_CMD="$USE_ASAN_OPTIONS sudo --preserve-env timeout -s INT 900 /usr/local/bin/dpdk-testpmd -l $CORE_LIST $VDEV_ARG -- --forward-mode=$FWDMODE --auto-start --txq=$QUEUE_COUNT --rxq=$QUEUE_COUNT --txonly-multi-flow --record-burst-stats --record-core-cycles --stats 2 $SENDER_IP_ARG --hot-plug --nb-cores=$FWD_CORES"
# mana likes having the number of forwarding cores specified
if is_mana_vm; then
    #RUN_DPDK_CMD+=" --nb-cores=$FWD_CORES"
    RUN_DPDK_CMD+=" --txd=$DESCRIPTOR_COUNT --rxd=$DESCRIPTOR_COUNT"
fi

# write the command out to a file and run that
# to avoid weird parsing of the command in the event the last arg is empty
echo "#! /bin/sh" > ./rerun-dpdk-testpmd.sh
echo "$RUN_DPDK_CMD" >> ./rerun-dpdk-testpmd.sh
echo 'exit $?' >> ./rerun-dpdk-testpmd.sh
sudo chmod +x ./rerun-dpdk-testpmd.sh


tee ~/repro_testpmd.txt < ./rerun-dpdk-testpmd.sh

# NOTE: don't remove this leading period
#shellcheck disable=SC1091
. ./rerun-dpdk-testpmd.sh 2>&1
EXIT_CODE=$?

## Start MANA multiple queue test (example assumes > 64 cores)
#sudo timeout -s INT 120 dpdk-testpmd -l "1-$LAST_CORE" "$VDEV_ARG" -- --forward-mode="$FWDMODE" --auto-start --nb-cores="$FWD_CORES"  --txd=128 --rxd=128 --txq=32 --rxq=32 --stats 2  $SENDER_IP_ARG

exit $EXIT_CODE;

## stupid setup test: sudo dpdk-testpmd --vdev="7870:00:00.0,mac=7c:1e:52:3d:d6:7a,mac=7c:1e:52:3d:d4:83" -l 2,3 -- --forward-mode=txonly -a --stats 2