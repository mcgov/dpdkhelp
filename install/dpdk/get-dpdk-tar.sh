#! /bin/bash

# author: mamcgove at microsoft aka @mcgov on github

# todo: make this have arguments
SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# install/.cache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.cache"
[[ -d "$CACHE_DIR" ]] || mkdir -p "$CACHE_DIR"

if [[ -z "$DPDK_TAR_LINK" ]]; then
    DPDK_TAR_LINK="https://git.dpdk.org/dpdk/snapshot/dpdk-25.07.tar.xz"
fi
DPDK_TAR_PATH=$(basename $DPDK_TAR_LINK)
wget  "$DPDK_TAR_LINK"\
 || { echo "wget for dpdk tarball failed!"; exit 1; }

tar xzvf "$DPDK_TAR_PATH" \
|| { echo "tar expand for rdma-core tarball failed!"; exit 1; }

DPDK_TAR_DIR=$(tar --list --file $DPDK_TAR_PATH | cut -d '/' -f 1 | uniq )

if [[ -z "$DPDK_TAR_DIR" ]]; then
    echo "Could not determine top level dir for '$DPDK_TAR_PATH'!"
    exit 1
fi

# this is gross idk. maybe better to ask for confirmation and destroy/rename?
readlink -f $DPDK_TAR_DIR > "$CACHE_DIR"/dpdk_src_dir


git clone https://github.com/mcgov/devname.git "$DPDK_TAR_DIR"/examples/devname \
|| { echo "Could not clone to $DPDK_TAR_DIR/examples/devname!"; exit 1; }

exit 0