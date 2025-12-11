#! /bin/bash

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# dpdkhelp/.dpdkcache
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
find "$ROOT_DIR" -name .dpdkcache | while read -r folder; do
    rm -rf "$folder"
done