#! /bin/bash

# author: mamcgove at microsoft aka @mcgov on github

# path helpers
SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# dpdkhelp/.dpdkcache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.dpdkcache"
[[ -d "$CACHE_DIR" ]] && [[ -f "$CACHE_DIR/vdev_arg" ]] || {
    echo "Error: no vdev_arg file was found cached in $CACHE_DIR. Run setup/setup-netvsc-pmd --device eth1[,eth2] first.";
    exit 1; 
}

OPTIONS="p:P:m:t:hT:"
LONGOPTIONS="proc-id:,port-mask:,mac:,run-time:,help,timeout:,asan"
# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    # If getopt has complained about wrong arguments, print the error message and exit
    exit 2
fi

# Use eval to properly handle the parsed options
eval set -- "$PARSED"
RUN_TIME=120
PROC_ID=0
TIMEOUT=0
# Process the options
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [--proc-id 0|1 ] [--port-mask <hex> ] [--help]"
            exit 0
            ;;
        -p|--proc-id)
            PROC_ID="$2"
            shift 2
            ;;
        -P|--port-mask)
            PORT_MASK="$2"
            shift 2
            ;;
        -t|--run-time)
            RUN_TIME="$2"
            shift 2
            ;;
        -T|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --asan)
            USE_ASAN_OPTIONS='true';
            shift
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
if [[ -z "$PORT_MASK" ]]; then
    echo "Error: provide port mask with -P";
    exit 1;
fi

if [[ -z "$RUN_TIME" ]]; then
    RUN_TIME="160"
fi

# and splat them into the command
ulimit -n 204800;
VDEV_ARG=$(cat "$CACHE_DIR/vdev_arg")
echo "Using $VDEV_ARG as the vdev arg args"
## Check number of cores is >= 64

# set this closer to the invocation to avoid asan-izing anything else
if [[ -n "$USE_ASAN_OPTIONS" ]]; then
    ASAN_OPTIONS=detect_leaks=false
    # shellcheck disable=SC2155
    LD_PRELOAD=$(find /usr/lib -name libasan.so) || echo "Warning, could not find libasan in /usr/lib" 1>&2;
fi

if [[ $PROC_ID -eq 0 ]] && [[ -n $(lspci -d 1414:00ba:0200) ]]; then
    sudo -E ASAN_OPTIONS="$ASAN_OPTIONS" LD_PRELOAD="$LD_PRELOAD" /usr/local/share/dpdk/examples/devname/build/devname "$VDEV_ARG"
    sleep 2
fi
((USE_CORE=PROC_ID*2))
((USE_CORE+=3))

# save the command to a repro file
echo "sudo -E ASAN_OPTIONS=\"$ASAN_OPTIONS\" LD_PRELOAD=\"$LD_PRELOAD\" /usr/local/share/dpdk/examples/multi_process/symmetric_mp/build/symmetric_mp $VDEV_ARG " \
 "-l $USE_CORE -n 4 --proc-type auto " \
 "-- -p $PORT_MASK --num-procs 2 " \
 "--proc-id $PROC_ID" > ~/repro_symmetric_mp_"$PROC_ID".sh

# and run it
if [[ $TIMEOUT -gt 0 ]]; then
    sudo --preserve-env timeout --preserve-status "$TIMEOUT" ASAN_OPTIONS="$ASAN_OPTIONS" LD_PRELOAD="$LD_PRELOAD" /usr/local/share/dpdk/examples/multi_process/symmetric_mp/build/symmetric_mp "$VDEV_ARG" \
        -l $USE_CORE -n 4 --proc-type auto \
        -- -p "$PORT_MASK" --num-procs 2 \
        --proc-id "$PROC_ID"
else
    sudo --preserve-env ASAN_OPTIONS="$ASAN_OPTIONS" LD_PRELOAD="$LD_PRELOAD" /usr/local/share/dpdk/examples/multi_process/symmetric_mp/build/symmetric_mp $VDEV_ARG \
        -l $USE_CORE -n 4 --proc-type auto \
        -- -p "$PORT_MASK" --num-procs 2 \
        --proc-id "$PROC_ID"
fi
