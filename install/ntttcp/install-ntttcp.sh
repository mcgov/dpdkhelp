#! /bin/bash

NTTTCP_DIR="./ntttcp"
if [ -d "$NTTTCP_DIR" ]; then
    rm -rf "$NTTTCP_DIR"
fi
git clone "https://github.com/microsoft/ntttcp-for-linux" "$NTTTCP_DIR"
pushd "$NTTTCP_DIR"/src || { echo "Could not pushd to $NTTTCP_DIR" >&2 ; exit $?; }
make && sudo make install
popd ||  ( echo "Could not popd from $NTTTCP_DIR" >&2 ; exit $? )