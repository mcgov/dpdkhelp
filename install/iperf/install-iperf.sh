#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

"$(dirname "$(readlink -f "$(dirname "$0")")")/setup/apt-retry.sh" install -y iperf3 iperf
exit $?