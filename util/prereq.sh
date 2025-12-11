#! /bin/bash
#shellcheck disable=SC2002,SC2015
OPTIONS="h"
LONGOPTIONS="required:,available:,help"

# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    # If getopt has complained about wrong arguments, print the error message and exit.
    exit 2
fi

# Use eval to properly handle the parsed options
eval set -- "$PARSED"
# Initialize variables
# Process the options
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 --required <requirement_version> --available <available_version>"
            echo "    returns 0 if available version meets or exceeds requirement version."
            exit 0
            ;;
        --required)
            REQUIRED_VERSION="$2"
            shift 2
            ;;
        --available)
            AVAILABLE_VERSION="$2"
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

[[ -n "$REQUIRED_VERSION" ]] && [[ -n "$AVAILABLE_VERSION" ]] || { 
    echo "Error: must provide both versions with --required and --available flags." 1>&2
    echo "Found --required '$REQUIRED_VERSION' and --available '$AVAILABLE_VERSION'" 1>&2
    exit 1;
}
# dpkg compare if it's available
command -v dpkg > /dev/null && {
        dpkg --compare-versions "$REQUIRED_VERSION" le "$AVAILABLE_VERSION"; exit $?;
}
