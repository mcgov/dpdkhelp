#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# end-to-end dpdk l3fwd test (sender -> forwarder running l3fwd -> receiver, ntttcp for traffic):
#   1. deploy the sender, forwarder and receiver VMs with deploy/deploy.sh --template l3fwd
#   2. install dpdk and dependencies with setup-cluster.sh
#   3. set up routes, the pmd and run l3fwd + ntttcp with run/run-l3fwd.sh
#   4. delete the resource group, unless --keep is given
# the resource group is only ever deleted if this script created it.
# DPDK_GIT, DPDK_VERSION, RDMA_VERSION, etc. are passed through to setup-cluster.sh from the environment.
# AVSET_PROPERTIES_FILE and AVSET_TAGS_FILE are passed through to deploy/deploy.sh from the environment.

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")

ssh_key_path="$HOME/.ssh/id_rsa"
RESOURCE_GROUP=""
LOG_DIR=""
DEPLOY_ARGS=( --template l3fwd )
SETUP_ARGS=( --install-deps --install-dpdk )
RUN_ARGS=()

OPTIONS="hg:l:i:t:"
LONGOPTIONS="help,resource-group:,location:,key:,vm-size:,forwarder-vm-size:,subnet-pairs:,admin-user:,ssh-source:,nsg-rules:,"
LONGOPTIONS+="rg-tag:,avset-tag:,avset-properties:,install-rdma-core,install-kernel,pmd:,timeout:,ports:,threads:,log-dir:,keep,keep-on-failure"
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    exit 2
fi
eval set -- "$PARSED"
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 -l|--location <region> [-g|--resource-group <name>] [-i|--key <ssh private key>] [--keep] [--keep-on-failure]"
            echo "  deploy:  [--vm-size <size>] [--forwarder-vm-size <size>] [--subnet-pairs <1-3>] [--admin-user <user>]"
            echo "           [--ssh-source <cidr>] [--nsg-rules <json|file>] [--rg-tag key=value]... [--avset-tag key=value]..."
            echo "           [--avset-properties <json|file>]"
            echo "  setup:   [--install-rdma-core] [--install-kernel]  (dpdk and deps are always installed)"
            echo "  run:     [--pmd auto|netvsc|mana] [-t|--timeout <ntttcp seconds>] [--ports <n>] [--threads <n>]"
            echo "           [--log-dir <dir>] [-- <run-dpdk-l3fwd.sh args>]"
            echo "  --subnet-pairs: sender/receiver subnet pairs, the forwarder needs 1 + 2 * pairs nics"
            echo "      (Standard_D8s_v5 supports 4 nics, so more than 1 pair needs a bigger --forwarder-vm-size)"
            echo "  --log-dir: default <dpdkhelp>/logs/<resource group>/<timestamp>"
            echo "  --keep: keep the resource group and VMs after the test"
            echo "  --keep-on-failure: keep them only if a step fails"
            echo "  the resource group defaults to \$USER-l3fwd-<timestamp>, and is never deleted if it already existed."
            echo "  env: AVSET_PROPERTIES_FILE and AVSET_TAGS_FILE (json object files) are used by deploy/deploy.sh"
            exit 0
            ;;
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        -i|--key)
            ssh_key_path="$2"
            shift 2
            ;;
        --forwarder-vm-size)
            DEPLOY_ARGS+=( --param "forwarderVmSize=$2" )
            shift 2
            ;;
        --subnet-pairs)
            [[ "$2" =~ ^[1-3]$ ]] || { echo "Error: --subnet-pairs must be 1-3"; exit 1; }
            DEPLOY_ARGS+=( --param "subnetPairs=$2" )
            shift 2
            ;;
        --vm-size|--admin-user|--ssh-source|--nsg-rules|--rg-tag|--avset-tag|--avset-properties)
            DEPLOY_ARGS+=( "$1" "$2" )
            [[ "$1" == "--admin-user" ]] && ADMIN_USER="$2"
            shift 2
            ;;
        --install-rdma-core|--install-kernel)
            SETUP_ARGS+=( "$1" )
            shift
            ;;
        --pmd|-t|--timeout|--ports|--threads)
            RUN_ARGS+=( "$1" "$2" )
            shift 2
            ;;
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        --keep)
            KEEP="true"
            shift
            ;;
        --keep-on-failure)
            KEEP_ON_FAILURE="true"
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
L3FWD_ARGS=( "$@" )

[[ -n "$LOCATION" ]] || { echo "Error: provide --location"; exit 1; }
[[ -f "$ssh_key_path" ]] && [[ -f "$ssh_key_path.pub" ]] || {
    echo "Error: need ssh key $ssh_key_path and $ssh_key_path.pub, use -i|--key"
    exit 1
}
[[ -n "$RESOURCE_GROUP" ]] || RESOURCE_GROUP="$USER-l3fwd-$(date +%m%d-%H%M%S)"
[[ -n "$LOG_DIR" ]] || LOG_DIR="$SCRIPT_DIR/logs/$RESOURCE_GROUP/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR" || exit 1
echo "=== logs in $LOG_DIR"
VMS_FILE="$LOG_DIR/vms.txt"

CREATED_RG=""
FAILED="true"
function cleanup() {
    local keep_reason=""
    [[ -n "$KEEP" ]] && keep_reason="--keep"
    [[ -n "$FAILED" ]] && [[ -n "$KEEP_ON_FAILURE" ]] && keep_reason="--keep-on-failure"
    [[ -z "$CREATED_RG" ]] && keep_reason="resource group existed before this run"
    if [[ -n "$keep_reason" ]]; then
        echo "keeping resource group $RESOURCE_GROUP ($keep_reason)"
        [[ -s "$VMS_FILE" ]] && cat "$VMS_FILE"
        echo "cleanup: az group delete --name $RESOURCE_GROUP --yes"
    else
        echo "deleting resource group $RESOURCE_GROUP..."
        az group delete --name "$RESOURCE_GROUP" --yes --no-wait \
            || echo "Error: could not delete $RESOURCE_GROUP, run: az group delete --name $RESOURCE_GROUP --yes"
    fi
}

function fail() {
    echo "Error: $*" 1>&2
    exit 1
}

RG_EXISTS=$(az group exists --name "$RESOURCE_GROUP" | tr -d '\r')
case "$RG_EXISTS" in
    true) ;;
    false) CREATED_RG="true" ;;
    # don't guess, a wrong answer here could delete a resource group we didn't create
    *) fail "could not check if resource group $RESOURCE_GROUP exists, are you logged in to az?" ;;
esac
trap cleanup EXIT

echo "=== deploying l3fwd VMs to $RESOURCE_GROUP in $LOCATION"
"$SCRIPT_DIR/deploy/deploy.sh" -g "$RESOURCE_GROUP" -l "$LOCATION" --ssh-key "$ssh_key_path.pub" \
    --output-file "$VMS_FILE" "${DEPLOY_ARGS[@]}" || fail "deploy failed"

# vm names end with -fwd, -snd and -rcv (see deploy/l3fwd.bicep)
FORWARDER=""
SENDER=""
RECEIVER=""
while IFS='=' read -r vm ip; do
    [[ -n "$ip" ]] || continue
    case "$vm" in
        *-fwd) FORWARDER="${ADMIN_USER:-$USER}@$ip" ;;
        *-snd) SENDER="${ADMIN_USER:-$USER}@$ip" ;;
        *-rcv) RECEIVER="${ADMIN_USER:-$USER}@$ip" ;;
    esac
done < "$VMS_FILE"
[[ -n "$FORWARDER" ]] && [[ -n "$SENDER" ]] && [[ -n "$RECEIVER" ]] || \
    fail "expected -fwd, -snd and -rcv VMs in $VMS_FILE"
HOSTS="$FORWARDER,$SENDER,$RECEIVER"

echo "=== waiting for ssh on $HOSTS"
for host in "$FORWARDER" "$SENDER" "$RECEIVER"; do
    for ((attempt = 0; attempt < 30; attempt++)); do
        ssh -i "$ssh_key_path" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
            "$host" true 2> /dev/null && continue 2
        sleep 10
    done
    fail "could not ssh to $host"
done

echo "=== nics"
for host in "$FORWARDER" "$SENDER" "$RECEIVER"; do
    # pci class 0200 is ethernet, -nn adds the vendor:device ids (1414:00ba is mana, 15b3 is mellanox)
    ssh -n -i "$ssh_key_path" "$host" 'lspci -nn -d ::0200 2> /dev/null || echo "lspci not found"' 2>&1 \
        | sed -u "s/^/[$host] /"
done | tee "$LOG_DIR/nics.log"

# dpdk is only used on the forwarder, but it builds in parallel on all hosts so it doesn't add much time
echo "=== installing dpdk on $HOSTS"
"$SCRIPT_DIR/setup-cluster.sh" -i "$ssh_key_path" --hosts "$HOSTS" "${SETUP_ARGS[@]}" \
    2>&1 | tee "$LOG_DIR/setup-cluster.log"
[[ "${PIPESTATUS[0]}" -eq 0 ]] || fail "setup-cluster failed, see $LOG_DIR/setup-cluster.log"

echo "=== running l3fwd"
"$SCRIPT_DIR/run/run-l3fwd.sh" -i "$ssh_key_path" --forwarder "$FORWARDER" --sender "$SENDER" --receiver "$RECEIVER" \
    --log-dir "$LOG_DIR" "${RUN_ARGS[@]}" -- "${L3FWD_ARGS[@]}" || fail "l3fwd run failed, see $LOG_DIR"

FAILED=""
echo "=== done, logs in $LOG_DIR"
[[ -s "$LOG_DIR/summary.txt" ]] && cat "$LOG_DIR/summary.txt"
exit 0
