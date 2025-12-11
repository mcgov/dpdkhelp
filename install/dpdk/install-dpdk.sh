#! /bin/bash
#shellcheck disable=SC2002,SC2015
SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
OPTIONS="d:h"
LONGOPTIONS="dir:,help"

# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    # If getopt has complained about wrong arguments, print the error message and exit
    exit 2
fi

# Use eval to properly handle the parsed options
eval set -- "$PARSED"
# Initialize variables
DPDK_DIR=""
# Process the options
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [-d|--dir <dpdk_dir>] [-h|--help]"
            echo "This script builds dpdk."
            echo "  if -d|--dir is not specified, the script will use the current directory."
            exit 0
            ;;
        -d|--dir)
            DPDK_DIR="$2"
            cd "$DPDK_DIR" || {
                echo "ERROR: $0 could not change to directory $DPDK_DIR"
                exit 1;
            }
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

[[ "$1" == "--debug" ]] && BUILD_TYPE_ARG=( "--buildtype=debug" )
# "-Db_sanitize=address" leaving this off for now

# this is ugly, but we need to patch symmetric_mp
cp "$SCRIPT_DIR"/symmetric_mp_main.c ./examples/multi_process/symmetric_mp/main.c \
&& echo "copied patched symmetric_mp main.c to examples/multi_process/symmetric_mp/main.c" \
|| {
    echo "ERROR: Could not copy patched symmetric_mp main.c, test will not work on MANA!"
    exit 1;
}
echo "export ASAN_SYMBOLIZER_PATH=\$( which llvm-symbolizer )" >> ~/.bashrc
CC=clang CXX=clang++ meson setup -Dexamples=l3fwd,multi_process/symmetric_mp,devname \
    -Denable_drivers=net/mana,*/mlx*,bus/vmbus,bus/vdev,net/netvsc,net/ring,net/virtio,net/bonding,bus/auxiliary,common/*,net/vdev_netvsc \
    -Denable_apps=app/test-pmd -Ddisable_drivers=net/failsafe -Dmax_lcores=192 --buildtype=debug "${BUILD_TYPE_ARG[@]}" build \
    || { echo  "meson setup failed!"; exit 1; }

for libdir in /lib/clang/*/lib/linux; do
    if [ -d "$libdir" ]; then
        export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$libdir"
        echo "export LD_LIBRARY_PATH=$LD_LIBRARY_PATH" >> ~/.bashrc
        break
    fi
done

# NOTE: this bashrc update is lost if the image is generalized
echo "export ASAN_OPTIONS=detect_leaks=false" >> ~/.bashrc

# shellcheck disable=SC1090
source ~/.bashrc

cd build \
|| { echo "cd build failed: $?"; exit 1; }

ninja \
|| { echo "ninja build failed!"; exit 1; }

sudo ninja install \
|| { echo "ninja install failed!"; exit 1; }

sudo cp "$SCRIPT_DIR"/symmetric_mp_main.c /usr/local/share/dpdk/examples/multi_process/symmetric_mp/main.c \
|| { 
    echo "ERROR: Could not copy patched symmetric_mp main.c to /usr/local/share/dpdk/examples/multi_process/symmetric_mp/main.c"; 
    exit 1;    
}
PATH_UPDATE="PATH=$PATH:/usr/local/bin"
for example in "l3fwd" "multi_process/symmetric_mp" "devname"; do
    cd /usr/local/share/dpdk/examples/"$example" \
    && sudo make static \
    || {
        echo "Could not build example app $example!";
        
        #exit 1;
    }
    PATH_UPDATE="$PATH_UPDATE:/usr/local/share/dpdk/examples/$example/build"
done
# NOTE: this will get lost if the image is generalized
echo "export $PATH_UPDATE" >> ~/.bashrc

exit 0