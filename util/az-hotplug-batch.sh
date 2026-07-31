#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github
# Collect NIC names from a comma separated list of private IPs and update
# enableAcceleratedNetworking for all of them with a single ARM deployment.

OPTIONS="g:h"
LONGOPTIONS="rg:,toggle,help,private-ip:,set:,template:,what-if,api-version:"
# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    # If getopt has complained about wrong arguments, print the error message and exit
    exit 2
fi

RGNAME=""
TOGGLE=0
PRIVATE_IP_ADDRESSES=""
SET_VALUE=0
WHAT_IF=0
API_VERSION="2023-04-01"
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
TEMPLATE_FILE="$SCRIPT_DIR/accelerate-networking-update.json"

# Use eval to properly handle the parsed options
eval set -- "$PARSED"
export MSYS_NO_PATHCONV=1;
# Process the options
while true; do
    case "$1" in
        -h|--help)
            echo "
Usage: $0 --rg <resource-group-name> --private-ip <comma,separated,nic,private,ips> [--set 0|1] [--toggle] [--what-if] [--template <arm-template>] [--api-version <version>]

Every NIC matching one of the private IPs is redeployed in a single ARM
deployment with its existing configuration preserved; only
enableAcceleratedNetworking is changed."
            exit 0
            ;;
        -g|--rg)
            RGNAME="$2"
            shift 2
            ;;
        --private-ip)
            PRIVATE_IP_ADDRESSES="$2"
            shift 2
            ;;
        --toggle)
            TOGGLE=1
            shift
            ;;
        --set)
            SET_VALUE="$2"
            shift 2
            ;;
        --template)
            TEMPLATE_FILE="$2"
            shift 2
            ;;
        --what-if)
            WHAT_IF=1
            shift
            ;;
        --api-version)
            API_VERSION="$2"
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
set -o pipefail;

if [[ -z "$RGNAME" ]]; then
    echo "No resource group provided, use --rg <resource-group-name>" 1>&2;
    exit 2;
fi
if [[ -z "$PRIVATE_IP_ADDRESSES" ]]; then
    echo "No private IPs provided, use --private-ip <comma,separated,nic,private,ips>" 1>&2;
    exit 2;
fi
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "Template file $TEMPLATE_FILE not found" 1>&2;
    exit 2;
fi
if ! command -v jq > /dev/null; then
    echo "jq is required but was not found in PATH" 1>&2;
    exit 2;
fi

# turn the comma separated list into an array of trimmed addresses
IPS=()
IFS=',' read -r -a _raw_ips <<< "$PRIVATE_IP_ADDRESSES"
for _ip in "${_raw_ips[@]}"; do
    _ip="${_ip//[$'\t\r\n ']/}"
    [[ -z "$_ip" ]] && continue;
    IPS+=("$_ip");
done

if [[ "${#IPS[@]}" -eq 0 ]]; then
    echo "No valid private IPs parsed from '$PRIVATE_IP_ADDRESSES'" 1>&2;
    exit 2;
fi

# collect every nic in the resource group once, as "name<tab>ip<tab>id" rows
declare -A NIC_NAME_BY_IP=()
declare -A NIC_ID_BY_IP=()
while IFS=$'\t' read -r _nic_name _nic_ip _nic_id; do
    _nic_name="${_nic_name//[$'\t\r\n']/}"
    _nic_ip="${_nic_ip//[$'\t\r\n']/}"
    _nic_id="${_nic_id//[$'\t\r\n']/}"
    [[ -z "$_nic_name" || -z "$_nic_ip" || -z "$_nic_id" ]] && continue;
    NIC_NAME_BY_IP["$_nic_ip"]="$_nic_name"
    NIC_ID_BY_IP["$_nic_ip"]="$_nic_id"
done < <(az network nic list -g "$RGNAME" \
        --query "[].[name, ipConfigurations[0].privateIPAddress, id]" -o tsv) \
    || {
        echo "Failed to list NICs in resource group $RGNAME" 1>&2;
        exit 1;
    }

NIC_NAMES=()
NIC_IDS=()
for _ip in "${IPS[@]}"; do
    _nic="${NIC_NAME_BY_IP[$_ip]}"
    if [[ -z "$_nic" ]]; then
        echo "No NIC with private IP $_ip found in resource group $RGNAME" 1>&2;
        exit 1;
    fi
    echo "Found NIC $_nic with private IP $_ip"
    NIC_NAMES+=("$_nic")
    NIC_IDS+=("${NIC_ID_BY_IP[$_ip]}")
done

# Deployments are a full PUT of each resource, so the existing NIC body has to be
# round tripped. Fetch the raw ARM representation and keep only the writable
# fields; read only members (etag, provisioningState, macAddress, virtualMachine,
# expanded child resources, ...) would be rejected or silently reset.
RAW_NICS=$(az resource show --ids "${NIC_IDS[@]}" --api-version "$API_VERSION" -o json) \
    || {
        echo "Failed to read NIC configuration from resource group $RGNAME" 1>&2;
        exit 1;
    }

read -r -d '' JQ_CLEAN <<'JQ' || true
def refonly: if . == null then null else {id: .id} end;
def refs: if . == null then null else [ .[] | {id: .id} ] end;
def prune: with_entries(select(.value != null));
def ipconfig:
  {
    name: .name,
    properties: ({
      primary: .properties.primary,
      privateIPAddress: .properties.privateIPAddress,
      privateIPAllocationMethod: .properties.privateIPAllocationMethod,
      privateIPAddressVersion: .properties.privateIPAddressVersion,
      subnet: (.properties.subnet | refonly),
      publicIPAddress: (.properties.publicIPAddress | refonly),
      gatewayLoadBalancer: (.properties.gatewayLoadBalancer | refonly),
      loadBalancerBackendAddressPools: (.properties.loadBalancerBackendAddressPools | refs),
      loadBalancerInboundNatRules: (.properties.loadBalancerInboundNatRules | refs),
      applicationGatewayBackendAddressPools: (.properties.applicationGatewayBackendAddressPools | refs),
      applicationSecurityGroups: (.properties.applicationSecurityGroups | refs),
      virtualNetworkTaps: (.properties.virtualNetworkTaps | refs)
    } | prune)
  };
def dns:
  (.properties.dnsSettings // {})
  | {dnsServers: .dnsServers, internalDnsNameLabel: .internalDnsNameLabel}
  | prune
  | if length == 0 then null else . end;
def nic:
  {
    name: .name,
    location: .location,
    tags: .tags,
    extendedLocation: .extendedLocation,
    properties: ({
      ipConfigurations: [ .properties.ipConfigurations[] | ipconfig ],
      dnsSettings: dns,
      networkSecurityGroup: (.properties.networkSecurityGroup | refonly),
      enableIPForwarding: .properties.enableIPForwarding,
      disableTcpStateTracking: .properties.disableTcpStateTracking,
      auxiliaryMode: .properties.auxiliaryMode,
      auxiliarySku: .properties.auxiliarySku,
      nicType: .properties.nicType
    } | prune)
  } | prune;
(if type == "array" then . else [.] end) | map(nic)
JQ

NICS_JSON=$(jq "$JQ_CLEAN" <<< "$RAW_NICS") \
    || {
        echo "Failed to normalize NIC configuration" 1>&2;
        exit 1;
    }

if [[ "$(jq 'length' <<< "$NICS_JSON")" -ne "${#NIC_NAMES[@]}" ]]; then
    echo "Expected ${#NIC_NAMES[@]} NIC bodies, refusing to deploy" 1>&2;
    exit 1;
fi

PARAM_FILE=$(mktemp -t nics-XXXXXX.json)
# shellcheck disable=SC2064
trap "rm -f '$PARAM_FILE'" EXIT
jq -n --argjson nics "$NICS_JSON" \
    '{"$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#","contentVersion":"1.0.0.0","parameters":{"nics":{"value":$nics}}}' \
    > "$PARAM_FILE" \
    || {
        echo "Failed to write deployment parameters" 1>&2;
        exit 1;
    }

deploy_accelerated_networking() {
    local _value="$1"
    local _cmd=(az deployment group create)
    [[ "$WHAT_IF" -eq 1 ]] && _cmd=(az deployment group what-if);
    echo "Setting accelerated networking to $_value for NICs: ${NIC_NAMES[*]}"
    "${_cmd[@]}" \
        --resource-group "$RGNAME" \
        --template-file "$TEMPLATE_FILE" \
        --parameters "@$PARAM_FILE" \
        --parameters enableAcceleratedNetworking="$_value" \
        || {
            echo "Failed to set accelerated networking to $_value" 1>&2;
            return 1;
        }
}

if [[ "$TOGGLE" -eq 1 ]]; then
    echo "Toggling accelerated networking for ${#NIC_NAMES[@]} NIC(s)"
    deploy_accelerated_networking false || exit 1;
    sleep 5;
    deploy_accelerated_networking true || exit 1;
else
    case "$SET_VALUE" in
        1|true|True|TRUE) _set="true" ;;
        0|false|False|FALSE) _set="false" ;;
        *)
            echo "Invalid --set value '$SET_VALUE', expected 0|1|true|false" 1>&2;
            exit 2;
            ;;
    esac
    deploy_accelerated_networking "$_set" || exit 1;
fi

exit 0
