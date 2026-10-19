#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# set up and run a dpdk-testpmd sender/receiver pair on two VMs over ssh.
# run this from your machine; dpdkhelp must already be copied to ~/dpdkhelp on both VMs
# with dpdk (and dpdk-devname) installed, see setup-cluster.sh.
#
# all netvsc nics other than eth0 are used on each VM. the receiver's nic ips are cached
# during setup and passed to the sender with --tx-dst, which matches each sender port
# to the receiver ip on the same subnet.
#
# usage: run-testpmd-pair.sh --sender user@ip --receiver user@ip [--pmd netvsc|mana]
#            [-t|--timeout <seconds>] [--skip-setup] [--log-dir <dir>] [-i <key>] [-- <run-dpdk-testpmd.sh args>]
# args after -- are passed to run-dpdk-testpmd.sh on both VMs (ex: --queues 4 --core-list 2,4,6,8)
# env: START_DELAY seconds to wait for the receiver to start before the sender (default 15)

ssh_key_path="$HOME/.ssh/id_rsa"
PMD="netvsc"
TIMEOUT=120
# seconds to let the receiver start before starting the sender
START_DELAY="${START_DELAY:-15}"
LOG_DIR="."
OPTIONS="hi:t:"
LONGOPTIONS="help,key:,sender:,receiver:,pmd:,timeout:,skip-setup,log-dir:"
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    exit 2
fi
eval set -- "$PARSED"
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 --sender user@ip --receiver user@ip [--pmd netvsc|mana] [-t|--timeout <seconds>]"
            echo "          [--skip-setup] [--log-dir <dir>] [-i <ssh_key>] [-- <run-dpdk-testpmd.sh args>]"
            echo "  --skip-setup: reuse the nic setup and cache from a previous run"
            echo "  args after -- are passed to run-dpdk-testpmd.sh on both VMs"
            echo "  note: requires passwordless sudo on both VMs (see setup/passwordless-sudo.sh)"
            exit 0
            ;;
        -i|--key)
            ssh_key_path="$2"
            shift 2
            ;;
        --sender)
            SENDER="$2"
            shift 2
            ;;
        --receiver)
            RECEIVER="$2"
            shift 2
            ;;
        --pmd)
            PMD="$2"
            if [[ "$PMD" != "netvsc" ]] && [[ "$PMD" != "mana" ]]; then
                echo "Error: --pmd must be netvsc or mana"
                exit 1
            fi
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
                echo "Error: --timeout must be a number of seconds"
                exit 1
            fi
            shift 2
            ;;
        --skip-setup)
            SKIP_SETUP="true"
            shift
            ;;
        --log-dir)
            LOG_DIR="$2"
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
EXTRA_ARGS=( "$@" )

[[ -n "$SENDER" ]] && [[ -n "$RECEIVER" ]] || {
    echo "Error: provide --sender and --receiver"
    exit 1
}
mkdir -p "$LOG_DIR" || exit 1

function rssh() {
    local host="$1"
    shift
    ssh -n -i "$ssh_key_path" "$host" "$@"
}

function quote_args() {
    # quote args for the remote shell, prints nothing for no args
    [[ $# -gt 0 ]] && printf '%q ' "$@"
}

function setup_host() {
    # usage: setup_host <host> <role> ; sets HOST_NICS to the nics that were set up
    local host="$1" role="$2"
    HOST_NICS=$(rssh "$host" dpdkhelp/util/list-dpdk-nics.sh) || {
        echo "Error: could not find nics on $role $host" 1>&2
        return 1
    }
    echo "[$role] setting up $PMD pmd on $host with nics: $HOST_NICS"
    rssh "$host" "dpdkhelp/setup/quick-setup.sh --pmd $(quote_args "$PMD") --device $(quote_args "$HOST_NICS")" || {
        echo "Error: setup failed on $role $host" 1>&2
        return 1
    }
}

function run_testpmd() {
    # usage: run_testpmd <host> <role> <timeout> <run-dpdk-testpmd.sh args...>
    local host="$1" role="$2" timeout_s="$3"
    shift 3
    rssh "$host" "cd dpdkhelp && timeout -s INT $timeout_s ./run/run-dpdk-testpmd.sh $(quote_args "$@")" 2>&1 \
        | tee "$LOG_DIR/testpmd-$role.log" | sed -u "s/^/[$role] /"
    local rc="${PIPESTATUS[0]}"
    # testpmd runs until it's interrupted, so a timeout is the expected way out
    case "$rc" in
        0|124|130) return 0 ;;
        *) echo "Error: testpmd on $role $host exited with $rc" 1>&2; return "$rc" ;;
    esac
}

RECEIVER_NICS=""
if [[ -z "$SKIP_SETUP" ]]; then
    setup_host "$SENDER" sender || exit 1
    setup_host "$RECEIVER" receiver || exit 1
    RECEIVER_NICS="$HOST_NICS"
fi

# collect the receiver ips from its nic cache (written during setup, before the nics were bound)
NIC_INFO=$(rssh "$RECEIVER" cat dpdkhelp/.dpdkcache/nic_info) || {
    echo "Error: could not read nic info cache from receiver $RECEIVER, run without --skip-setup" 1>&2
    exit 1
}
DST_IPS=()
while read -r _mac ifname cidrs; do
    [[ -z "$cidrs" ]] || [[ "$cidrs" == "-" ]] && continue
    # with --skip-setup, use every cached nic
    if [[ -n "$RECEIVER_NICS" ]] && [[ ",$RECEIVER_NICS," != *",$ifname,"* ]]; then
        continue
    fi
    IFS=',' read -r -a cidr_list <<< "$cidrs"
    for cidr in "${cidr_list[@]}"; do
        DST_IPS+=( "${cidr%/*}" )
    done
done <<< "$NIC_INFO"
if [[ "${#DST_IPS[@]}" -eq 0 ]]; then
    echo "Error: no receiver ips found in nic info cache on $RECEIVER" 1>&2
    exit 1
fi
DST_LIST=$(IFS=,; echo "${DST_IPS[*]}")
echo "receiver ips: $DST_LIST"

# receiver starts first and outlives the sender
RX_TIMEOUT=$((TIMEOUT + START_DELAY + 15))
run_testpmd "$RECEIVER" receiver "$RX_TIMEOUT" -m rxonly "${EXTRA_ARGS[@]}" &
RX_PID=$!
trap 'kill "$RX_PID" 2> /dev/null' EXIT INT TERM
sleep "$START_DELAY"

run_testpmd "$SENDER" sender "$TIMEOUT" -m txonly --tx-dst "$DST_LIST" "${EXTRA_ARGS[@]}"
TX_RC=$?
wait "$RX_PID"
RX_RC=$?
trap - EXIT INT TERM

UTIL_DIR="$(dirname "$(readlink -f "$(dirname "$0")")")/util"
{
    "$UTIL_DIR/testpmd-summary.sh" --direction tx --label "sender $SENDER" "$LOG_DIR/testpmd-sender.log"
    echo
    "$UTIL_DIR/testpmd-summary.sh" --direction rx --label "receiver $RECEIVER" "$LOG_DIR/testpmd-receiver.log"
} 2>&1 | tee "$LOG_DIR/summary.txt"

echo "logs: $LOG_DIR/testpmd-sender.log $LOG_DIR/testpmd-receiver.log $LOG_DIR/summary.txt"
if [[ "$TX_RC" -ne 0 ]] || [[ "$RX_RC" -ne 0 ]]; then
    echo "Error: sender exit $TX_RC, receiver exit $RX_RC"
    exit 1
fi
exit 0
