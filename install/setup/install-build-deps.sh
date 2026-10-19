#! /bin/bash
# SPDX-License-Identifier: MIT
"$(dirname "$(readlink -f "$0")")"/apt-retry.sh -y build-dep dpdk rdma-core