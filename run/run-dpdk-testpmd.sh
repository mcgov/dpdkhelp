#! /bin/bash
# author: mamcgove @microsoft.com

# run a packet-per-second test with dpdk-testpmd.
# this script sets up a test using the netvsc pmd
# you can use the same script to start a sender and receiver on two VMs
# `pps-dpdk-testpmd.sh rxonly` on the receiver
# `pps-dpdk-testpmd.sh txonly $SENDER_IP,$RECEIVER_IP` on the sender
SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# dpdkhelp/.cache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.cache"
[[ -d "$CACHE_DIR" ]] && [[ -f "$CACHE_DIR/vdev_args" ]] || {
    echo "Error: no vdev_args file was found cached in $CACHE_DIR. Run setup/setup-netvsc-pmd --device eth1[,eth2] first.";
    exit 1; 
}

OPTIONS="hm:t:"
LONGOPTIONS="mode:,tx-ip:,help,timeout:,queues:,core-list:,nb-cores:"
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

if [[ "$FWDMODE" == "txonly" ]]; then
    # txonly mode requires sender and receiver IP addresses
    # shellcheck disable=SC2015
    [[ -n "$SEND_IP" ]] && [[ -n "$RECV_IP" ]] ||  {
        echo "Error: txonly mode requires sender and receiver IP addresses"
        exit 1;
    }
fi

function range(){
    local _start=$1
    local _end=$2
    # allow step argument to skip indices
    local _step="$3"
    # keep track of count of items in range
    # to allow skipping indices
    local _counter=0;
    # default step of 1
    [[ -z "$_step" ]] && _step=1;
    # do the loop
    for ((i=_start; i<_end; i++))
    do
        ((_counter++%_step)) || echo "$i";
    done
}

function range_cs() {
    cores=(); 
    for i in $(range "$1" "$2" "$3");
    do 
        cores+=("$i"); 
    done
    csvcores="${cores[*]}"; 
    echo "${csvcores// /,}"
}

function floor() {
    local value=$1
    local n=$2
    # return the value or the floor n
    ((value > n )) && echo "$value" || echo "$n" 
}

function ceil() {
    local value=$1
    local n=$2
    # return the value or the ceil n
    ((value < n)) && echo "$value" || echo "$n" 
}

function floorpow2() {
    # floor a value to the nearest power of 2...
    # or 1 if the value is 1
    value="$1"
    bit=1
    while (( (bit << 1) <= value )); do
        ((bit=bit << 1))
    done
    echo "$bit"
}
function element_count_cs() {
    # count elements of a csv list
    local list_of_elements="$1"
    IFS=',' read -r -a elements <<< "$list_of_elements"
    echo "${#elements[@]}"
}
function is_mana_vm () {
    [[ -n $(lspci -d 1414:00ba:0200) ]]
}

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



VDEV_ARG=$(cat "$CACHE_DIR/vdev_args")




is_mana_vm \
&& DESCRIPTOR_COUNT=256 \
|| DESCRIPTOR_COUNT=""

# #check for MANA
# if is_mana_vm; then
#     # large MANA sizes require more careful consideration of NUMA and CPU caches
#     # So, ensure that only one lcore per cpu is used
#     LAST_CORE=$(lscpu | grep --fixed-strings 'NUMA node0 CPU(s):' | cut -f 2 -d ':' | xargs | cut -d '-' -f2)
#     #THREADS_PER_CORE=$(lscpu | grep --fixed-strings 'Thread(s) per core:' | cut -f 2 -d ':' | xargs | cut -d '-' -f2)
#     # if [[ $USE_CORE -gt $LAST_CORE ]]; then
#     #     echo "Warning! You may be using more cores than can fit on a single NUMA node in this VM." 1>&2
#     # fi
# fi

# log the testpmd command for future re-runs
# --log-level=mana,debug --log-level=netvsc,debug --log-level=vmbus,debug
RUN_DPDK_CMD="sudo timeout -s INT 900 /usr/local/bin/dpdk-testpmd -l $CORE_LIST $VDEV_ARG -- --forward-mode=$FWDMODE --auto-start --txq=$QUEUE_COUNT --rxq=$QUEUE_COUNT --txonly-multi-flow --record-burst-stats --record-core-cycles --stats 2 $SENDER_IP_ARG --hot-plug --nb-cores=$FWD_CORES"
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