#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# convenience functions for bash list and math

function range(){
    local _start=$1
    local _end=$2
    # allow step argument to skip indices
    local _step="$3"
    # keep track of count of items in range
    # to allow skipping indices
    local _counter=0;
    # default step of 1
    [[ -z "$_step" ]] && _step=1;
    # do the loop
    for ((i=_start; i<_end; i++))
    do
        ((_counter++%_step)) || echo "$i";
    done
}

function range_cs() {
    cores=(); 
    for i in $(range "$1" "$2" "$3");
    do 
        cores+=("$i"); 
    done
    csvcores="${cores[*]}"; 
    echo "${csvcores// /,}"
}

function floor() {
    local value=$1
    local n=$2
    # return the value or the floor n
    ((value > n )) && echo "$value" || echo "$n" 
}

function ceil() {
    local value=$1
    local n=$2
    # return the value or the ceil n
    ((value < n)) && echo "$value" || echo "$n" 
}

function floorpow2() {
    # floor a value to the nearest power of 2...
    # or 1 if the value is 1
    value="$1"
    bit=1
    while (( (bit << 1) <= value )); do
        ((bit=bit << 1))
    done
    echo "$bit"
}

function ceilpow2() {
    # ceil a value to the nearest power of 2...
    # or 1 if the value is 1
    value="$1"
    bit=1
    while (( (bit << 1) <= value )); do
        ((bit=bit << 1))
    done
    # shift one more time unless we were already a power of 2
    [[ "$bit" == "$1" ]] || ((bit=bit<<1));
    echo "$bit"
}

function element_count_cs() {
    # count elements of a csv list
    local list_of_elements="$1"
    # make an array and return the length
    IFS=',' read -r -a elements <<< "$list_of_elements"
    echo "${#elements[@]}"
}
function is_mana_vm () {
    # check for the mana pci id and return 0 if anything is found
    [[ -n $(lspci -d 1414:00ba:0200) ]]
}
function get_network_pci_devices () {
    # list all devices of device class network
    lspci -d ::0200
}
function damn() {
    echo "$@" 1>&2
}
function ip4_to_int() {
    # convert a dotted ipv4 address to an integer, fails on invalid input
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]+$ ]] && ((octet <= 255)) || return 1
    done
    echo "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}
function ip4_in_cidr() {
    # usage: ip4_in_cidr <ip> <net>/<prefix> ; returns 0 if ip is in the subnet
    local ip_int net_int prefix mask
    ip_int=$(ip4_to_int "$1") || return 1
    net_int=$(ip4_to_int "${2%/*}") || return 1
    prefix="${2#*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] && ((prefix <= 32)) || return 1
    mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    (( (ip_int & mask) == (net_int & mask) ))
}
function int_to_ip4() {
    echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"
}
function ip4_network() {
    # usage: ip4_network <ip>/<prefix> ; prints the network address in cidr form (ex: 10.0.1.0/24)
    local ip_int prefix mask
    ip_int=$(ip4_to_int "${1%/*}") || return 1
    prefix="${1#*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] && ((prefix <= 32)) || return 1
    mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    echo "$(int_to_ip4 $(( ip_int & mask )))/$prefix"
}
function ip4_to_ipv6_lpm() {
    # usage: ip4_to_ipv6_lpm <ip> ; ipv4-mapped ipv6 /56 prefix for the ip's /24, for l3fwd ipv6 rules.
    # dpdk doesn't accept shortened ipv6 addresses.
    local a b c d
    ip4_to_int "$1" > /dev/null || return 1
    IFS=. read -r a b c d <<< "$1"
    printf '0000:0000:0000:0000:0000:FFFF:%02x%02x:%02x00/56\n' "$a" "$b" "$c"
}
