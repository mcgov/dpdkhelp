#! /bin/bash

# get eth devices on the system, ignoring loopback. 
# note: not sure if this will include bridges unintentionally.
# author: @mcgov on github ( mamcgove@microsoft.com )

# NOTE: not finished

read -a devices < <(ip --br  link show | grep BROADCAST | awk '{ print $1;}')

# track nic associations
declare -A puppets
for master in "${devices[@]}"; do
    # check if any nics are masters of other nics
    puppet=$(ip link show master "$master") && puppets["$master"]="$puppet"
done


for master in "${!puppets[@]}"; do
    echo "$master -> ${puppets["$master"]}"
done
    
