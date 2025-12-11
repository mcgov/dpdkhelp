#! /bin/bash

export DEBIAN_FRONTEND=noninteractive; sudo apt install -y iperf3
export DEBIAN_FRONTEND=noninteractive; sudo apt install -y iperf
exit $?