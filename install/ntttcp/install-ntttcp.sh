#! /bin/bash

# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

NTTTCP_DIR="./ntttcp"
if [ -d "$NTTTCP_DIR" ]; then
    rm -rf "$NTTTCP_DIR"
fi
git clone "https://github.com/microsoft/ntttcp-for-linux" "$NTTTCP_DIR"
pushd "$NTTTCP_DIR"/src || { echo "Could not pushd to $NTTTCP_DIR" >&2 ; exit 1; }
#shellcheck disable=SC2015
make && sudo make install || { echo "Could not make ntttcp in $(pwd)" >&2 ; exit 1; }
popd ||  { echo "Could not popd from $NTTTCP_DIR" >&2 ; exit ; }