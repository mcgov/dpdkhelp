#! /bin/bash

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

function damn() {
    echo "$@" 1>&2
}