#! /bin/bash
# DEBIAN_FRONTEND=noninteractive sudo apt install -y rdma-core && exit 0;
OPTIONS="h"
LONGOPTIONS="32bit,help"
# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    # If getopt has complained about wrong arguments, print the error message and exit
    exit 2
fi

# Use eval to properly handle the parsed options
eval set -- "$PARSED"
DPDK_BUILD_32BIT=""
# Process the options
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [--32bit] [--help]"
            exit 0
            ;;
        --32bit)
            DPDK_BUILD_32BIT="true"
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

CMAKE_ARGS_I386='-DIN_PLACE=0 -DNO_MAN_PAGES=1 -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_C_COMPILER=/usr/bin/i686-linux-gnu-gcc -DCMAKE_C_FLAGS=-m32'
CMAKE_ARGS_DEFAULT='-DIN_PLACE=0 -DNO_MAN_PAGES=1 -DCMAKE_INSTALL_PREFIX=/usr'
if [[ -n "$DPDK_BUILD_32BIT" ]]; then
    yes '' | sudo DEBIAN_FRONTEND=noninteractive apt install -y gcc-i686-linux-gnu pkg-config
    CMAKE_ARGS="$CMAKE_ARGS_I386"
    export PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig
else
    CMAKE_ARGS="$CMAKE_ARGS_DEFAULT"
fi
cmake $CMAKE_ARGS \
|| { echo "cmake for rdma-core failed!" ; exit 1; }

sudo make -j \
|| { echo "make for rdma-core failed!" ; exit 1; }

sudo make install -j \
|| { echo "make install for rdma-core failed!" ; exit 1; }

exit 0