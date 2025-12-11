#! /bin/bash

# NOTE: not finished, this script is more for reference.


# get eth devices on the system, ignoring loopback. 
# note: not sure if this will include bridges unintentionally.
# author: @mcgov on github ( mamcgove@microsoft.com )


#! /bin/bash

# this script fetches information about master nics
# we're cool and metal so I'm calling these 'master and puppet' pairs

read -a devices < <(ip --br  link show | grep BROADCAST | awk '{ print $1; }')

# track nic associations
declare -A puppets
for master in "${devices[@]}"; do
    # check if any nics are masters of other nics
    puppet=$(ip link show master "$master") && puppets["$master"]="$puppet"
done


for master in "${!puppets[@]}"; do
    echo "$master -> ${puppets["$master"]}"
done
    
# get device info for specific pci device (includes driver, -d 1414:00ba:0200 for mana only ) lspci -k -s $slot 
# basename $(readlink ls /sys/class/net/eth0/device/driver)
# find /sys/bus/vmbus/drivers/hv_netvsc/ -type l  # find links in driver path