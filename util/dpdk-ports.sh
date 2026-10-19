#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# list the dpdk ports an app will forward on, using dpdk-devname (github.com/mcgov/devname).
# owned ports (ex: mana/mlx ports under a netvsc port) are skipped.
#
# usage: dpdk-ports.sh [--devname <path>] [--devname-output <file>] [-- <eal args>]
#   eal args default to the cached vdev_arg, these must match the args used for the dpdk app
#   so the port ids line up.
# prints one '<port> <mac>' per line, mac is lowercase.

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# dpdkhelp/.dpdkcache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.dpdkcache"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/functions.sh"

DEVNAME_BIN=""
DEVNAME_OUTPUT_FILE=""
OPTIONS="h"
LONGOPTIONS="help,devname:,devname-output:"
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    exit 2
fi
eval set -- "$PARSED"
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [--devname <path>] [--devname-output <file>] [-- <eal args>]"
            echo "  --devname-output: parse saved dpdk-devname output instead of running it"
            exit 0
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
    # devname prints ports with printf, which is block buffered into a pipe. If it dies during
    # rte_eal_cleanup the port lines are lost, so force line buffering.
    STDBUF=()
    command -v stdbuf > /dev/null && STDBUF=( stdbuf -oL -eL )
    DEVNAME_OUTPUT=$(sudo "${STDBUF[@]}" "$DEVNAME_BIN" "${EAL_ARGS[@]}" 2>&1)
    DEVNAME_RC=$?
    DEVNAME_CMD="sudo ${STDBUF[*]} $DEVNAME_BIN ${EAL_ARGS[*]}"
    if [[ -d "$CACHE_DIR" ]]; then
        printf '%s\n# exit code %s\n%s\n' "$DEVNAME_CMD" "$DEVNAME_RC" "$DEVNAME_OUTPUT" > "$CACHE_DIR/last-devname-output.txt"
    fi
fi

((found=0))
while read -r line; do
    port=""; owner_id=""; mac=""
    for field in $line; do
        case "$field" in
            port=*) port="${field#port=}" ;;
            owner_id=*) owner_id="${field#owner_id=}" ;;
            macaddr=*) mac="${field#macaddr=}" ;;
        esac
    done
    # owned ports (ex: mana ports under a netvsc port) aren't used for forwarding
    if [[ -n "$owner_id" ]] && [[ $((owner_id)) -ne 0 ]]; then
        damn "dpdk-ports: skipping port $port ($mac), owned by $owner_id"
        continue
    fi
    [[ -n "$port" ]] && [[ -n "$mac" ]] || continue
    echo "$port ${mac,,}"
    ((found++))
done < <(grep 'dpdk-devname found port=' <<< "$DEVNAME_OUTPUT")

if [[ -n "$DEVNAME_RC" ]] && [[ "$DEVNAME_RC" -ne 0 ]] && [[ "$found" -gt 0 ]]; then
    damn "Warning: dpdk-devname exited with $DEVNAME_RC after listing ports (crash during cleanup?), continuing"
fi
if [[ "$found" -eq 0 ]]; then
    damn "Error: dpdk-devname found no usable ports."
    [[ -n "$DEVNAME_CMD" ]] && damn "command: $DEVNAME_CMD (exit code $DEVNAME_RC)"
    damn "output:"
    damn "$DEVNAME_OUTPUT"
    exit 1
fi
exit 0
