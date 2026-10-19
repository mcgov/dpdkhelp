#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# deploy main.bicep with az cli: creates the resource group and two VMs with data nics for dpdk testing.
# usage: deploy.sh -g <resource-group> -l <region> [--vm-size <size>] [--admin-user <user>] [--ssh-key <pubkey path>]
#            [--data-nics <n>] [--name-prefix <prefix>] [--ssh-source <cidr>]
#            [--nsg-rules <json array | json file>] [--rg-tag key=value]... [--avset-tag key=value]...
#            [--avset-properties <json object | json file>] [--output-file <path>]
# the availability set is only created when avset tags or properties are given.
# env: AVSET_PROPERTIES_FILE and AVSET_TAGS_FILE (json object files) set the avset properties/tags,
#      --avset-properties overrides AVSET_PROPERTIES_FILE, --avset-tag pairs are added to AVSET_TAGS_FILE.

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
TEMPLATE="$SCRIPT_DIR/main.bicep"

ADMIN_USER="$USER"
SSH_KEY="$HOME/.ssh/id_rsa.pub"
PARAMS=()
RG_TAGS=()
AVSET_TAGS=()

function json_escape() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

function add_param() {
    # usage: add_param <name> <json value>
    PARAMS+=( "\"$1\": { \"value\": $2 }" )
}

function read_json_object_file() {
    # usage: read_json_object_file <path> <description> ; prints the file if it looks like a json object
    local content
    [[ -f "$1" ]] || { echo "Error: $2 file '$1' not found" 1>&2; return 1; }
    content=$(cat "$1") || return 1
    [[ "$content" =~ ^[[:space:]]*\{.*\}[[:space:]]*$ ]] || {
        echo "Error: $2 file '$1' must contain a json object" 1>&2
        return 1
    }
    printf '%s' "$content"
}

# env defaults, the command line options override these:
#   AVSET_PROPERTIES_FILE: json object file, same as --avset-properties <file>
#   AVSET_TAGS_FILE: json object file of tags, --avset-tag pairs are added to it
if [[ -n "$AVSET_PROPERTIES_FILE" ]]; then
    AVSET_PROPERTIES=$(read_json_object_file "$AVSET_PROPERTIES_FILE" AVSET_PROPERTIES_FILE) || exit 1
fi

OPTIONS="hg:l:"
LONGOPTIONS="help,resource-group:,location:,vm-size:,admin-user:,ssh-key:,data-nics:,name-prefix:,ssh-source:,nsg-rules:,rg-tag:,avset-tag:,avset-properties:,output-file:"
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    exit 2
fi
eval set -- "$PARSED"
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 -g|--resource-group <name> -l|--location <region> [--vm-size <size>]"
            echo "          [--admin-user <user>] [--ssh-key <pubkey path>] [--data-nics <n>] [--name-prefix <prefix>]"
            echo "          [--ssh-source <cidr>] [--nsg-rules <json array|file>] [--rg-tag key=value]... [--avset-tag key=value]..."
            echo "  --admin-user defaults to \$USER ($USER), --ssh-key defaults to ~/.ssh/id_rsa.pub"
            echo "  --nsg-rules: extra inbound rules (priority 101-200), ex:"
            echo "      '[{\"name\":\"allow-iperf\",\"destinationPortRange\":\"5201\",\"protocol\":\"Tcp\"}]'"
            echo "  --avset-tag: tag the availability set, ex: --avset-tag <tag=value>"
            echo "  --avset-properties: json object or file merged into the availability set properties, ex:"
            echo "      '{<property>:<value>}'"
            echo "  the availability set is only created when --avset-tag or --avset-properties is given"
            echo "  env: AVSET_PROPERTIES_FILE=<json file> (overridden by --avset-properties)"
            echo "       AVSET_TAGS_FILE=<json file> (--avset-tag pairs are added to it)"
            echo "  --output-file: also write the vm_name=ip lines to this file"
            exit 0
            ;;
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        --vm-size)
            add_param vmSize "\"$(json_escape "$2")\""
            shift 2
            ;;
        --admin-user)
            ADMIN_USER="$2"
            shift 2
            ;;
        --ssh-key)
            SSH_KEY="$2"
            shift 2
            ;;
        --data-nics)
            [[ "$2" =~ ^[0-9]+$ ]] || { echo "Error: --data-nics must be a number"; exit 1; }
            add_param dataNicCount "$2"
            shift 2
            ;;
        --name-prefix)
            add_param namePrefix "\"$(json_escape "$2")\""
            shift 2
            ;;
        --ssh-source)
            add_param sshSourceAddressPrefix "\"$(json_escape "$2")\""
            shift 2
            ;;
        --nsg-rules)
            if [[ -f "$2" ]]; then
                NSG_RULES=$(cat "$2") || exit 1
            else
                NSG_RULES="$2"
            fi
            shift 2
            ;;
        --avset-properties)
            if [[ -f "$2" ]]; then
                AVSET_PROPERTIES=$(cat "$2") || exit 1
            else
                AVSET_PROPERTIES="$2"
            fi
            [[ "$AVSET_PROPERTIES" =~ ^[[:space:]]*\{ ]] || { echo "Error: --avset-properties must be a json object or a file containing one"; exit 1; }
            shift 2
            ;;
        --output-file)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --rg-tag)
            RG_TAGS+=( "$2" )
            shift 2
            ;;
        --avset-tag)
            [[ "$2" == *=* ]] || { echo "Error: --avset-tag must be key=value"; exit 1; }
            AVSET_TAGS+=( "$2" )
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "unrecognized argument: $1"
            exit 1
            ;;
    esac
done

[[ -n "$RESOURCE_GROUP" ]] && [[ -n "$LOCATION" ]] || {
    echo "Error: provide --resource-group and --location"
    exit 1
}
[[ -n "$ADMIN_USER" ]] || { echo "Error: no --admin-user and \$USER is not set"; exit 1; }
[[ -f "$SSH_KEY" ]] || { echo "Error: ssh public key $SSH_KEY not found, use --ssh-key"; exit 1; }
command -v az > /dev/null || { echo "Error: az cli not found"; exit 1; }

add_param location "\"$(json_escape "$LOCATION")\""
add_param adminUsername "\"$(json_escape "$ADMIN_USER")\""
add_param sshPublicKey "\"$(json_escape "$(tr -d '\r\n' < "$SSH_KEY")")\""
[[ -n "$NSG_RULES" ]] && add_param nsgRules "$NSG_RULES"

# AVSET_TAGS_FILE: json object of tags, --avset-tag pairs are added to it (and win on duplicate keys)
AVSET_JSON=""
if [[ -n "$AVSET_TAGS_FILE" ]]; then
    AVSET_JSON=$(read_json_object_file "$AVSET_TAGS_FILE" AVSET_TAGS_FILE) || exit 1
    # strip the outer braces so the --avset-tag pairs can be appended
    AVSET_JSON="${AVSET_JSON#*\{}"
    AVSET_JSON="${AVSET_JSON%\}*}"
    [[ "$AVSET_JSON" =~ ^[[:space:]]*$ ]] && AVSET_JSON=""
fi
for tag in "${AVSET_TAGS[@]}"; do
    AVSET_JSON+="${AVSET_JSON:+, }\"$(json_escape "${tag%%=*}")\": \"$(json_escape "${tag#*=}")\""
done
[[ -n "$AVSET_JSON" ]] && add_param availabilitySetTags "{ $AVSET_JSON }"
[[ -n "$AVSET_PROPERTIES" ]] && add_param availabilitySetProperties "$AVSET_PROPERTIES"

# pass parameters as a file, inline json gets mangled by some shells (ex: windows az from wsl)
PARAMS_FILE=$(mktemp --suffix=.json)
trap 'rm -f "$PARAMS_FILE"' EXIT
{
    echo '{'
    echo '  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",'
    echo '  "contentVersion": "1.0.0.0",'
    echo '  "parameters": {'
    for ((p = 0; p < ${#PARAMS[@]}; p++)); do
        # values may span multiple lines (ex: json from a file), only separate whole params
        printf '    %s%s\n' "${PARAMS[$p]}" "$( ((p < ${#PARAMS[@]} - 1)) && echo ',')"
    done
    echo '  }'
    echo '}'
} > "$PARAMS_FILE"

# the windows az cli (ex: from wsl) needs a windows path to the template
if [[ "$(command -v az)" == /mnt/* ]] && command -v wslpath > /dev/null; then
    TEMPLATE=$(wslpath -w "$TEMPLATE")
    PARAMS_ARG="@$(wslpath -w "$PARAMS_FILE")"
else
    PARAMS_ARG="@$PARAMS_FILE"
fi

RG_ARGS=()
[[ "${#RG_TAGS[@]}" -gt 0 ]] && RG_ARGS=( --tags "${RG_TAGS[@]}" )

az group create --name "$RESOURCE_GROUP" --location "$LOCATION" \
    "${RG_ARGS[@]}" --output none || {
    echo "Error: could not create resource group $RESOURCE_GROUP"
    exit 1
}

DEPLOYMENT_NAME="dpdkhelp-$(date +%Y%m%d-%H%M%S)"
echo "deploying $DEPLOYMENT_NAME to $RESOURCE_GROUP in $LOCATION..."
az deployment group create --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" \
    --template-file "$TEMPLATE" --parameters "$PARAMS_ARG" --output none || {
    echo "Error: deployment $DEPLOYMENT_NAME failed"
    exit 1
}

VM_ADDRESSES=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" \
    --query 'properties.outputs.vmAddresses.value[]' --output tsv | tr -d '\r')
HOST_LIST=()
while IFS='=' read -r _vm ip; do
    [[ -n "$ip" ]] && HOST_LIST+=( "$ADMIN_USER@$ip" )
done <<< "$VM_ADDRESSES"
HOSTS=$(IFS=,; echo "${HOST_LIST[*]}")
echo "next steps:"
echo "  $(dirname "$SCRIPT_DIR")/setup-cluster.sh --hosts $HOSTS --install-deps --install-dpdk"
echo "  $(dirname "$SCRIPT_DIR")/run/run-testpmd-pair.sh --sender ${HOST_LIST[0]} --receiver ${HOST_LIST[1]}"
echo "  cleanup: az group delete --name $RESOURCE_GROUP"
echo "deployed VMs:"
echo "$VM_ADDRESSES"
[[ -n "$OUTPUT_FILE" ]] && echo "$VM_ADDRESSES" > "$OUTPUT_FILE"
[[ "${#HOST_LIST[@]}" -gt 0 ]] || { echo "Error: no VM addresses found in deployment outputs"; exit 1; }
exit 0
