#! /bin/bash

# author: mamcgove at microsoft aka @mcgov on github

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# install/.cache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.cache"
[[ -d "$CACHE_DIR" ]] || mkdir -p "$CACHE_DIR"

OPTIONS="G:R:"
LONGOPTIONS="git:,ref:"

# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    # If getopt has complained about wrong arguments, print the error message and exit
    exit 2
fi

# Use eval to properly handle the parsed options
eval set -- "$PARSED"

# Initialize variables
rgname=""
INSTALL_KERNEL=""
# Process the options
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [-g|--group] [--kernel]"
            exit 0
            ;;
        -G|--git)
            DPDK_GIT_SOURCE="$2"
            shift 2
            ;;
        -R|--ref)
            DPDK_GIT_REF="$2"
            shift 2
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
function handle_exit () {
    echo "$2" 1>&2
    [[ -d ~/dpdk ]] && rm -rf ~/dpdk
    exit "$1"
}

if [ -z "$DPDK_GIT_SOURCE" ]; then
    DPDK_GIT_SOURCE="https://dpdk.org/git/dpdk"
fi;
if [ -z "$DPDK_GIT_REF" ]; then
    DPDK_GIT_REF="v24.11"
fi

git clone "$DPDK_GIT_SOURCE" ./dpdk \
|| handle_exit $? "could not checkout DPDK from $DPDK_GIT_SOURCE"

readlink -f ./dpdk > "$CACHE_DIR/dpdk_src_dir"

pushd dpdk \
|| handle_exit $? "could not pushd to dpdk directory!"

git checkout "$DPDK_GIT_REF"  \
|| handle_exit $? "could not checkout DPDK branch from $DPDK_GIT_REF"

cd examples \
|| handle_exit $? "could not cd to dpdk/examples!";

git clone https://github.com/mcgov/devname.git \
|| handle_exit $? "could not clone devname repository"

popd || handle_exit $? "could not popd from dpdk directory!"

#echo "dpdk" > ~/dpdk_src_dir

exit 0