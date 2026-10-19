#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# set up and run a dpdk-l3fwd test over ssh: sender -> forwarder (dpdk l3fwd as an NVA) -> receiver.
# based on the LISA verify_dpdk_l3fwd_ntttcp_tcp test (microsoft/lisa dpdkutil.py).
# run this from your machine; dpdkhelp must already be copied to ~/dpdkhelp on all VMs and dpdk
# (with the l3fwd and devname examples) installed on the forwarder, see setup-cluster.sh.
#
# expected topology (see deploy/l3fwd.bicep), eth0 is left alone on every VM for ssh:
#    sender         forwarder         receiver
#    eth0 ---------- eth0 ------------ eth0        mgmt subnet
#    nic(A0) ------- nic(A0)                       subnet A0
#                    nic(B0) --------- nic(B0)     subnet B0
#    nic(A1) ------- nic(A1)                       subnet A1 (more pairs are optional)
#                    nic(B1) --------- nic(B1)     subnet B1
# the sender's data subnets are paired with the receiver's in sorted order (A0<->B0, A1<->B1, ...).
# azure must route each A subnet's traffic for its B subnet through the forwarder (and back), with
# ip forwarding on the forwarder nics; deploy/l3fwd.bicep does that.
#
# steps:
#   1. cache the nic info (mac, subnet) on all VMs, install ntttcp on the sender/receiver,
#      set up hugepages and the pmd on all forwarder data nics
#   2. on the sender/receiver: route the remote subnet via the forwarder nic ip and add a
#      permanent neighbor entry for the forwarder nic mac (nothing answers arp once it's bound to dpdk)
#   3. check that the sender and receiver can't ping each other yet, a reply means traffic is
#      leaking around the forwarder and the test would measure the wrong path
#   4. start l3fwd on the forwarder with an lpm rule and --eth-dest per port
#   5. run ntttcp from the sender to the receiver on each subnet pair
#
# usage: run-l3fwd.sh --forwarder user@ip --sender user@ip --receiver user@ip [--pmd auto|netvsc|mana]
#            [-t|--timeout <seconds>] [--ports <n>] [--threads <n>] [--skip-setup] [--log-dir <dir>]
#            [-i <key>] [-- <run-dpdk-l3fwd.sh args>]

ssh_key_path="$HOME/.ssh/id_rsa"
PMD="auto"
TIMEOUT=30
NTTTCP_PORTS=64
NTTTCP_THREADS=64
LOG_DIR="."
OPTIONS="hi:t:"
LONGOPTIONS="help,key:,forwarder:,sender:,receiver:,pmd:,timeout:,ports:,threads:,skip-setup,log-dir:"
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    exit 2
fi
eval set -- "$PARSED"
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 --forwarder user@ip --sender user@ip --receiver user@ip [--pmd auto|netvsc|mana]"
            echo "          [-t|--timeout <seconds>] [--ports <n>] [--threads <n>] [--skip-setup] [--log-dir <dir>]"
            echo "          [-i <ssh_key>] [-- <run-dpdk-l3fwd.sh args>]"
            echo "  --pmd: auto (default) picks mana if the VM has a mana nic, otherwise netvsc"
            echo "  -t|--timeout: ntttcp run time in seconds (default $TIMEOUT)"
            echo "  --ports: ntttcp receiver ports per subnet pair (-P, default $NTTTCP_PORTS)"
            echo "  --threads: ntttcp sender threads per receiver port (-n, default $NTTTCP_THREADS)"
            echo "  --skip-setup: reuse the nic setup and cache from a previous run"
            echo "  args after -- are passed to run-dpdk-l3fwd.sh on the forwarder (ex: --queues 2)"
            echo "  note: requires passwordless sudo on all VMs (see setup/passwordless-sudo.sh)"
            exit 0
            ;;
        -i|--key)
            ssh_key_path="$2"
            shift 2
            ;;
        --forwarder)
            FORWARDER="$2"
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
            if [[ "$PMD" != "netvsc" ]] && [[ "$PMD" != "mana" ]] && [[ "$PMD" != "auto" ]]; then
                echo "Error: --pmd must be netvsc, mana or auto"
                exit 1
            fi
            shift 2
            ;;
        -t|--timeout|--ports|--threads)
            if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: $1 must be a number"
                exit 1
            fi
            case "$1" in
                --ports) NTTTCP_PORTS="$2" ;;
                --threads) NTTTCP_THREADS="$2" ;;
                *) TIMEOUT="$2" ;;
            esac
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
L3FWD_ARGS=( "$@" )

[[ -n "$FORWARDER" ]] && [[ -n "$SENDER" ]] && [[ -n "$RECEIVER" ]] || {
    echo "Error: provide --forwarder, --sender and --receiver"
    exit 1
}
mkdir -p "$LOG_DIR" || exit 1
UTIL_DIR="$(dirname "$(readlink -f "$(dirname "$0")")")/util"
# shellcheck disable=SC1091
source "$UTIL_DIR/functions.sh"

function rssh() {
    local host="$1"
    shift
    ssh -n -i "$ssh_key_path" "$host" "$@"
}

function quote_args() {
    # quote args for the remote shell, prints nothing for no args
    [[ $# -gt 0 ]] && printf '%q ' "$@"
}

function fail() {
    echo "Error: $*" 1>&2
    exit 1
}

function setup_endpoint() {
    # usage: setup_endpoint <host> <role> ; caches nic info and installs ntttcp, sets HOST_NICS
    local host="$1" role="$2"
    HOST_NICS=$(rssh "$host" dpdkhelp/util/list-dpdk-nics.sh) || {
        echo "Error: could not find data nics on $role $host" 1>&2
        return 1
    }
    echo "[$role] caching nic info for $HOST_NICS on $host"
    rssh "$host" "dpdkhelp/util/cache-nic-info.sh --device $(quote_args "$HOST_NICS")" || return 1
    # install ntttcp before changing any routes: package installs can restart systemd-networkd,
    # which re-applies netplan and undoes the routes and neighbor entries.
    echo "[$role] installing ntttcp on $host"
    rssh "$host" 'command -v ntttcp > /dev/null || (cd ~ && dpdkhelp/install/ntttcp/install-ntttcp.sh)' \
        > "$LOG_DIR/ntttcp-install-$role.log" 2>&1 || {
        echo "Error: could not install ntttcp on $role $host, see $LOG_DIR/ntttcp-install-$role.log" 1>&2
        return 1
    }
    rssh "$host" 'sudo ufw disable > /dev/null 2>&1 || true'
}

function setup_forwarder() {
    local host="$1"
    HOST_NICS=$(rssh "$host" dpdkhelp/util/list-dpdk-nics.sh) || {
        echo "Error: could not find data nics on forwarder $host" 1>&2
        return 1
    }
    echo "[forwarder] setting up $PMD pmd on $host with nics: $HOST_NICS"
    rssh "$host" "dpdkhelp/setup/quick-setup.sh --pmd $(quote_args "$PMD") --device $(quote_args "$HOST_NICS")" \
        2>&1 | tee "$LOG_DIR/setup-forwarder.log" | sed -u "s/^/[forwarder] /"
    [[ "${PIPESTATUS[0]}" -eq 0 ]] || {
        echo "Error: setup failed on forwarder $host, see $LOG_DIR/setup-forwarder.log" 1>&2
        return 1
    }
}

function read_nics() {
    # usage: read_nics <host> <comma separated nics or empty for all>
    # prints '<network/prefix> <ip> <mac> <ifname>' per cached ipv4 address, sorted by network
    local host="$1" nics="$2" info mac ifname cidrs cidr
    info=$(rssh "$host" cat dpdkhelp/.dpdkcache/nic_info) || return 1
    while read -r mac ifname cidrs; do
        [[ -z "$cidrs" ]] || [[ "$cidrs" == "-" ]] && continue
        if [[ -n "$nics" ]] && [[ ",$nics," != *",$ifname,"* ]]; then
            continue
        fi
        IFS=',' read -r -a cidr_list <<< "$cidrs"
        for cidr in "${cidr_list[@]}"; do
            echo "$(ip4_network "$cidr") ${cidr%/*} $mac $ifname"
        done
    done <<< "$info" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n
}

SENDER_NICS=""
RECEIVER_NICS=""
FORWARDER_NICS=""
if [[ -z "$SKIP_SETUP" ]]; then
    setup_endpoint "$SENDER" sender || exit 1
    SENDER_NICS="$HOST_NICS"
    setup_endpoint "$RECEIVER" receiver || exit 1
    RECEIVER_NICS="$HOST_NICS"
    setup_forwarder "$FORWARDER" || exit 1
    FORWARDER_NICS="$HOST_NICS"
fi

SND_INFO=$(read_nics "$SENDER" "$SENDER_NICS") || fail "could not read nic info cache from sender $SENDER"
RCV_INFO=$(read_nics "$RECEIVER" "$RECEIVER_NICS") || fail "could not read nic info cache from receiver $RECEIVER"
FWD_INFO=$(read_nics "$FORWARDER" "$FORWARDER_NICS") || fail "could not read nic info cache from forwarder $FORWARDER"
mapfile -t SND_LINES < <(grep . <<< "$SND_INFO")
mapfile -t RCV_LINES < <(grep . <<< "$RCV_INFO")
[[ "${#SND_LINES[@]}" -gt 0 ]] || fail "no data nic ips cached on sender $SENDER"
[[ "${#RCV_LINES[@]}" -gt 0 ]] || fail "no data nic ips cached on receiver $RECEIVER"
[[ "${#SND_LINES[@]}" -eq "${#RCV_LINES[@]}" ]] || \
    echo "Warning: sender has ${#SND_LINES[@]} data subnets and receiver has ${#RCV_LINES[@]}, extra subnets are unused"

function forwarder_nic_on() {
    # usage: forwarder_nic_on <network/prefix> ; prints '<ip> <mac>' of the forwarder nic on that subnet
    awk -v net="$1" '$1 == net { print $2, $3; exit }' <<< "$FWD_INFO"
}

PAIR_COUNT=$(( ${#SND_LINES[@]} < ${#RCV_LINES[@]} ? ${#SND_LINES[@]} : ${#RCV_LINES[@]} ))
PEER_ARGS=()
PAIRS=()
for ((p = 0; p < PAIR_COUNT; p++)); do
    read -r snd_net snd_ip snd_mac snd_if <<< "${SND_LINES[$p]}"
    read -r rcv_net rcv_ip rcv_mac rcv_if <<< "${RCV_LINES[$p]}"
    [[ "$snd_net" != "$rcv_net" ]] || fail "sender and receiver are both on $snd_net, they need different subnets"
    read -r fwd_a_ip fwd_a_mac <<< "$(forwarder_nic_on "$snd_net")"
    read -r fwd_b_ip fwd_b_mac <<< "$(forwarder_nic_on "$rcv_net")"
    [[ -n "$fwd_a_ip" ]] || fail "forwarder has no cached nic on sender subnet $snd_net"
    [[ -n "$fwd_b_ip" ]] || fail "forwarder has no cached nic on receiver subnet $rcv_net"
    echo "pair $p: sender $snd_if $snd_ip -> forwarder $fwd_a_ip | $fwd_b_ip -> receiver $rcv_if $rcv_ip"

    rssh "$SENDER" "dpdkhelp/setup/l3fwd/setup-l3fwd-route.sh --route $(quote_args "$rcv_net,$fwd_a_ip,$fwd_a_mac")" \
        > "$LOG_DIR/route-sender-$p.log" 2>&1 || fail "could not set up routes on sender, see $LOG_DIR/route-sender-$p.log"
    rssh "$RECEIVER" "dpdkhelp/setup/l3fwd/setup-l3fwd-route.sh --route $(quote_args "$snd_net,$fwd_b_ip,$fwd_b_mac")" \
        > "$LOG_DIR/route-receiver-$p.log" 2>&1 || fail "could not set up routes on receiver, see $LOG_DIR/route-receiver-$p.log"

    PEER_ARGS+=( --peer "$snd_ip,$snd_mac" --peer "$rcv_ip,$rcv_mac" )
    PAIRS+=( "$snd_if $snd_ip $rcv_if $rcv_ip" )
done

function check_no_leak() {
    # usage: check_no_leak <host> <role> <src if> <src ip> <dst ip>
    # the forwarder nics are bound to dpdk with nothing running, so any reply took another path
    # (missing/undone guest routes, the azure route table, kernel forwarding on the forwarder, eth0...)
    local host="$1" role="$2" src_if="$3" src_ip="$4" dst_ip="$5" ping_cmd
    for ping_cmd in "ping -c 2 -W 1 -I $src_if $dst_ip" "ping -c 2 -W 1 $dst_ip"; do
        if rssh "$host" "$ping_cmd" >> "$LOG_DIR/leak-check-$role.log" 2>&1; then
            rssh "$host" "ip route get $dst_ip; ip route get $dst_ip from $src_ip oif $src_if" \
                >> "$LOG_DIR/leak-check-$role.log" 2>&1
            fail "traffic leaks before l3fwd started: '$ping_cmd' on $role $host got a reply, see $LOG_DIR/leak-check-$role.log"
        fi
    done
}
echo "checking that the test subnets can't reach each other before l3fwd starts..."
: > "$LOG_DIR/leak-check-sender.log"
: > "$LOG_DIR/leak-check-receiver.log"
for ((p = 0; p < PAIR_COUNT; p++)); do
    read -r snd_if snd_ip rcv_if rcv_ip <<< "${PAIRS[$p]}"
    check_no_leak "$SENDER" sender "$snd_if" "$snd_ip" "$rcv_ip"
    check_no_leak "$RECEIVER" receiver "$rcv_if" "$rcv_ip" "$snd_ip"
done
echo "ok, no replies without l3fwd"

# start l3fwd, it's stopped once ntttcp is done; the timeout is a backstop
L3FWD_LOG="$LOG_DIR/l3fwd-forwarder.log"
L3FWD_TIMEOUT=$((TIMEOUT + 120))
rssh "$FORWARDER" "cd dpdkhelp && timeout -s INT $L3FWD_TIMEOUT ./run/run-dpdk-l3fwd.sh $(quote_args "${PEER_ARGS[@]}" "${L3FWD_ARGS[@]}")" \
    > "$L3FWD_LOG" 2>&1 &
L3FWD_PID=$!
function stop_l3fwd() {
    # '[-]-rule_ipv4' keeps pkill from matching its own command line
    rssh "$FORWARDER" "sudo pkill -INT -f '[-]-rule_ipv4='" 2> /dev/null
}
trap 'stop_l3fwd; kill "$L3FWD_PID" 2> /dev/null' EXIT INT TERM

echo "[forwarder] waiting for l3fwd to start..."
for ((wait_s = 0; ; wait_s++)); do
    grep -q "entering main loop" "$L3FWD_LOG" 2> /dev/null && break
    kill -0 "$L3FWD_PID" 2> /dev/null || {
        sed "s/^/[forwarder] /" "$L3FWD_LOG"
        fail "l3fwd exited before starting, check the log for bad flags or init errors: $L3FWD_LOG"
    }
    ((wait_s < 60)) || fail "l3fwd did not start within 60s, see $L3FWD_LOG"
    sleep 1
done
grep -E "^(R |port |Note:|sudo )" "$L3FWD_LOG" | sed "s/^/[forwarder] /"

# log the route the kernel will use on each side, a failed connect can usually be traced to these
for ((p = 0; p < PAIR_COUNT; p++)); do
    read -r snd_if snd_ip rcv_if rcv_ip <<< "${PAIRS[$p]}"
    rssh "$SENDER" "ip route get $rcv_ip from $snd_ip oif $snd_if; ip neigh show dev $snd_if" \
        >> "$LOG_DIR/routes-sender.log" 2>&1
    rssh "$RECEIVER" "ip route get $snd_ip from $rcv_ip oif $rcv_if; ip neigh show dev $rcv_if" \
        >> "$LOG_DIR/routes-receiver.log" 2>&1
done

# ntttcp: one receiver/sender per subnet pair, each pair on its own port range
SERVER_PIDS=()
for ((p = 0; p < PAIR_COUNT; p++)); do
    read -r snd_if snd_ip rcv_if rcv_ip <<< "${PAIRS[$p]}"
    base_port=$((5001 + p * 1000))
    rssh "$RECEIVER" "timeout $((TIMEOUT + 60)) sudo bash -c 'ulimit -n 204800 && ntttcp -r$rcv_ip -p $base_port -P $NTTTCP_PORTS -t $TIMEOUT -W 1 -C 1 -b 1024k -e --show-nic-packets $rcv_if'" \
        > "$LOG_DIR/ntttcp-receiver-$p.log" 2>&1 &
    SERVER_PIDS+=( "$!" )
done
sleep 5
CLIENT_PIDS=()
for ((p = 0; p < PAIR_COUNT; p++)); do
    read -r snd_if snd_ip rcv_if rcv_ip <<< "${PAIRS[$p]}"
    base_port=$((5001 + p * 1000))
    echo "[sender] ntttcp $snd_ip -> $rcv_ip for ${TIMEOUT}s ($NTTTCP_PORTS ports x $NTTTCP_THREADS threads)"
    rssh "$SENDER" "timeout $((TIMEOUT + 60)) sudo bash -c 'ulimit -n 204800 && ntttcp -s$rcv_ip -p $base_port -P $NTTTCP_PORTS -n $NTTTCP_THREADS -t $TIMEOUT -W 1 -C 1 -b 64k --show-nic-packets $snd_if'" \
        > "$LOG_DIR/ntttcp-sender-$p.log" 2>&1 &
    CLIENT_PIDS+=( "$!" )
done
((ntttcp_failed=0))
for pid in "${CLIENT_PIDS[@]}" "${SERVER_PIDS[@]}"; do
    wait "$pid" || ((ntttcp_failed++))
done

stop_l3fwd
wait "$L3FWD_PID"
L3FWD_RC=$?
trap - EXIT INT TERM

function ntttcp_gbps() {
    # print the last reported throughput in a ntttcp log in Gbps, or nothing
    grep -oE 'throughput[[:space:]]*:[[:space:]]*[0-9.]+[KMG]?bps' "$1" 2> /dev/null | tail -n 1 \
        | sed -E 's/.*:[[:space:]]*//' \
        | awk '{ v = $0 + 0; u = $0; sub(/^[0-9.]+/, "", u)
                 if (u == "Kbps") v /= 1e6; else if (u == "Mbps") v /= 1e3; else if (u == "bps") v /= 1e9
                 printf "%.3f\n", v }'
}

{
    echo "== l3fwd ntttcp throughput (sender $SENDER -> forwarder $FORWARDER -> receiver $RECEIVER)"
    printf "%-6s %-34s %14s %14s\n" "pair" "sender -> receiver" "sender Gbps" "receiver Gbps"
    total_snd=0
    total_rcv=0
    for ((p = 0; p < PAIR_COUNT; p++)); do
        read -r snd_if snd_ip rcv_if rcv_ip <<< "${PAIRS[$p]}"
        snd_gbps=$(ntttcp_gbps "$LOG_DIR/ntttcp-sender-$p.log")
        rcv_gbps=$(ntttcp_gbps "$LOG_DIR/ntttcp-receiver-$p.log")
        printf "%-6s %-34s %14s %14s\n" "$p" "$snd_ip -> $rcv_ip" "${snd_gbps:--}" "${rcv_gbps:--}"
        total_snd=$(awk -v a="$total_snd" -v b="${snd_gbps:-0}" 'BEGIN { printf "%.3f", a + b }')
        total_rcv=$(awk -v a="$total_rcv" -v b="${rcv_gbps:-0}" 'BEGIN { printf "%.3f", a + b }')
    done
    printf "%-6s %-34s %14s %14s\n" "total" "" "$total_snd" "$total_rcv"
} > "$LOG_DIR/summary.txt" 2>&1
cat "$LOG_DIR/summary.txt"

echo "logs: $LOG_DIR (l3fwd-forwarder.log, ntttcp-*.log, summary.txt)"
case "$L3FWD_RC" in
    0|124|130) ;;
    *) fail "l3fwd on $FORWARDER exited with $L3FWD_RC, see $L3FWD_LOG" ;;
esac
[[ "$ntttcp_failed" -eq 0 ]] || fail "$ntttcp_failed ntttcp process(es) failed, see $LOG_DIR/ntttcp-*.log"
awk -v t="$total_rcv" 'BEGIN { exit !(t > 0) }' || \
    fail "0 Gbps through the forwarder, check the routes (routes-*.log), the dpdk port ids and the l3fwd log"
exit 0
