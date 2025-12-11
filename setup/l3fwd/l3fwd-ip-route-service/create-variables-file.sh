#! /bin/bash

# author: mamcgove at microsoft aka @mcgov on github

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
OPTIONS="g:d:r:"
LONGOPTIONS="gateway:,route-via:,destination:"

# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    # If getopt has complained about wrong arguments, print the error message and exit
    exit 2
fi

# Use eval to properly handle the parsed options
eval set -- "$PARSED"

# Process the options
while true; do
    case "$1" in
        -g|--gateway)
            GATEWAY_IP="$2"
            shift 2
            ;;
        -r|--route-via)
            ROUTE_VIA_SUBNET="$2"
            shift 2
            ;;
        -d|--destination)
            DESTINATION_ADDRESS="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1"
            exit 3
            ;;
    esac
done
echo export ROUTE_VIA_SUBNET="$ROUTE_VIA_SUBNET" \
| sudo tee -a "$SCRIPT_DIR"/variables.sh
echo export NEW_GATEWAY_IP="$GATEWAY_IP" \
| sudo tee -a "$SCRIPT_DIR"/variables.sh
echo export DESTINATION_ADDRESS="$DESTINATION_ADDRESS" \
| sudo tee -a "$SCRIPT_DIR"/variables.sh
bash "$SCRIPT_DIR"/setup-service.sh
exit $?