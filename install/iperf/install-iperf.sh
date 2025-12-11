#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

export DEBIAN_FRONTEND=noninteractive; sudo apt install -y iperf3
export DEBIAN_FRONTEND=noninteractive; sudo apt install -y iperf
exit $?