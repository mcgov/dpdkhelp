#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github
SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# install/.dpdkcache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.dpdkcache"
mkdir -p "$CACHE_DIR"
[[ -z "$RDMA_VERSION" ]] && RDMA_VERSION="58.0"
RDMA_CORE_TAR_LINK="https://github.com/linux-rdma/rdma-core/releases/download/v$RDMA_VERSION/rdma-core-$RDMA_VERSION.tar.gz"
wget $RDMA_CORE_TAR_LINK \
|| { echo "wget for rdma-core tarball failed!"; exit 1; }

RDMA_CORE_TAR_PATH=$(basename "$RDMA_CORE_TAR_LINK")
tar xzvf "$RDMA_CORE_TAR_PATH" \
|| { echo "tar expand for rdma-core tarball failed!"; exit 1; }

RDMA_TAR_DIR=$(tar --list --file "$RDMA_CORE_TAR_PATH" | cut -d '/' -f 1 | uniq )
echo "$RDMA_TAR_DIR" > "$CACHE_DIR"/rdma_src_dir;

exit 0