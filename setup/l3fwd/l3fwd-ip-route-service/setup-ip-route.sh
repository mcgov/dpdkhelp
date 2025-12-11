#! /bin/bash
#shellcheck disable=SC1091
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# setup-ip-route.sh
# A script to set up the service to persist the l3fwd ip route rules.
# Users should disable the service if they want to run other tests that need multiple nics.
TOOLS_DIR="/opt/lsg-tools/mmdpdk"
#_SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# note that these variables on a given VM are set by the pipeline automation.
# this script is designed to be run on the target VM, either the sender or receiver
# (not the forwarder.)
source "$TOOLS_DIR"/setup/l3fwd-ip-route-service/variables.sh

# check that the required variables are set.

[[ -z "$DESTINATION_ADDRESS" ]] && {
    echo "Destination address was not found. "\
        "Check that variables are set in: "\
        "$TOOLS_DIR/setup/l3fwd-ip-route-service/variables.sh "\
        "or set DESTINATION_ADDRESS in your shell";
    exit 0;
}
[[ -z "$ROUTE_VIA_SUBNET" ]] && {
    echo "Subnet to route traffic through was not found. "\
        "Check that variables are set in: "\
        "$TOOLS_DIR/setup/l3fwd-ip-route-service/variables.sh "\
        "or set ROUTE_VIA_SUBNET";
    exit 0;
}
[[ -z "$NEW_GATEWAY_IP" ]] && {
    echo "New gateway IP was not found. "\
        "Check that variables are set in: "\
        "$TOOLS_DIR/setup/l3fwd-ip-route-service/variables.sh "\
        "or set NEW_GATEWAY_IP";
    exit 0;
}

# It's more reliable to not assume a specific subnet prefix ending with .0/24 or .N/24.
# So, read the first three octets of the subnet and use that in a pattern match to find the interface. 
IFS='.' read -r -a disable_subnet_parts <<< "$DESTINATION_ADDRESS";
DISABLE_SUBNET_PREFIX="${disable_subnet_parts[0]}.${disable_subnet_parts[1]}.${disable_subnet_parts[2]}";
DISABLE_INTERFACE=$(ip -br addr | grep -P "$DISABLE_SUBNET_PREFIX.[0-9]+/24" | awk '{print $1}' 2> /dev/null)
[[ -z "$DISABLE_INTERFACE" ]] && {
    echo "Could not find interface for subnet $DISABLE_SUBNET_PREFIX in output:" 1>&2
    ip addr -br 1>&2
    exit 0; 
}

# ditto for the new subnet's interface.
IFS='.' read -r -a enable_subnet_parts <<< "$ROUTE_VIA_SUBNET";
ROUTE_VIA_SUBNET_PREFIX="${enable_subnet_parts[0]}.${enable_subnet_parts[1]}.${enable_subnet_parts[2]}";
ENABLE_INTERFACE=$(ip -br addr | grep -P "$ROUTE_VIA_SUBNET_PREFIX.[0-9]+/24" | awk '{print $1}' 2> /dev/null)
[[ -z "$ENABLE_INTERFACE" ]] && {
    echo "Could not find new source interface for subnet $ROUTE_VIA_SUBNET in output:" 1>&2
    ip addr -br 1>&2
    exit 0; 
}


# check if new rule is already in place.
if ip route | grep -q --fixed-strings "$DESTINATION_ADDRESS via $NEW_GATEWAY_IP dev $ENABLE_INTERFACE" ; then
    echo "Route already exists for $DESTINATION_ADDRESS via $NEW_GATEWAY_IP on $ENABLE_INTERFACE"
    exit 0;
fi

# remove any routes for the old interface.
# (this assumes there is one route defined for a specific interface when the VM starts.)
# shellcheck disable=SC2046
ip route del $(ip route | grep "$DISABLE_INTERFACE") || {
    echo "Could not identify routes to delete for $DISABLE_INTERFACE" 1>&2
    exit 1; 
}

# add the new route for the destination subnet via the new source interface using the new gateway address.
ip route add "$DESTINATION_ADDRESS" via "$NEW_GATEWAY_IP" dev "$ENABLE_INTERFACE" || {
    echo "Could not add route for $DESTINATION_ADDRESS via $NEW_GATEWAY_IP on $ENABLE_INTERFACE" 1>&2
    exit 1;
}
# finally, disable the old interface
ip link set "$DISABLE_INTERFACE" down || {
    echo "Could not disable interface $DISABLE_INTERFACE" 1>&2
    exit 1;
}

exit 0
