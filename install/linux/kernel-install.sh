#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# Script to install dependencies and setup an Azure VM with MANA for DPDK
# requires a MANA compatible kernel, rdma-core, and dpdk
# This script is for ubuntu server >= 22.04 and RHEL >= 8.4

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
#../setup
SETUP_DIR="$(dirname "$SCRIPT_DIR")/setup"
# install/.dpdkcache
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.dpdkcache"
[[ -d "$CACHE_DIR" ]] || mkdir -p "$CACHE_DIR"

OPTIONS="P:G:T:R:vhk"
LONGOPTIONS="patch:,git:,tar-url:,ref:,verbose,help,kasan,add-config:"

# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    # If getopt has complained about wrong arguments, print the error message and exit
    exit 2
fi
KASAN=""
# Use eval to properly handle the parsed options
eval set -- "$PARSED"

# Process the options
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [--patch <patch file>] [--git <git_repo_url>] [--tar-url <tar_url>] [--git-ref <git_ref>] [--verbose] [--help] [--add-config <config=option[, ...>]"
            exit 0
            ;;
        -P|--patch)
            PATCH_FILE="$2"
            shift 2
            ;;
        -G|--git)
            GIT_REPO="$2"
            shift 2
            ;;
        -R|--ref)
            export GIT_REF="$2"
            shift 2
            ;;
        -T|--tar-url)
            export TAR_URL="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE='true'
            shift 2
            ;;
        -k|--kasan)
            KASAN="true"
            shift
            ;;
        --add-config)
            ADD_CONFIGS="$2"
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

if [[ -n "$VERBOSE" ]]; then
    set -x
fi

function assert_success {
    if [ $? -ne 0 ]; then
        echo "Last call failed! Exiting..."
        exit 1
    fi
}

function check_and_append {
    #check that it's set
    #append if it wasn't present
    if ! grep "$2" < "$1" ; then
        echo "$2" >> "$1"
    fi;
}

function get_cores_for_build {
    CORES=$(lscpu -p | grep -c -P '[0-9]+,[0-9]+,[0-9]+')
    ((CORES=CORES-1))
    echo "$CORES"
    return 0
}
echo "STOP: did you update the kernel to latest? for ubuntu install and upgrade:"
echo "linux-azure linux-modules-extra-azure"
sleep 10

# NOTE for ubuntu 22.04:
# linux-azure and linux-modules-extra-azure installs 6.2
# for 5.15.0-1045 use linux-azure-lts-22.04 and linux-modules-extra-azure-22.04
# 6.2 doesn't require anything special other than rdma-core >=v44 and dpdk > 22.11
# 5.15.0-1045 has MANA backported but not ERDMA from rdma-core v43
# this throws off the driver_id fields and requires some tinkering for now.
# note the special steps in the rdma-core installation path below.

# hacky os detection, do not copypaste unless you want to look silly
# tested on 22.04 and RHEL 8.6/9.2
if command -v apt; then
    export DEBIAN_FRONTEND=noninteractive;
    sudo -E apt-get update -y -q;
    # shellcheck disable=SC2015
    "$SETUP_DIR/enable-build-deps.sh" && \
        sudo apt-get build-dep -y -q dpdk rdma-core && \
        sudo apt install flex bison libssl-dev libelf-dev python3-pip dwarves libnuma-dev libpcap-dev \
    || { 
        echo "could not install dependencies"; exit 1;
    }
elif command -v yum; then
    sudo yum update
    sudo yum -y groupinstall "Development Tools"
    sudo yum install -y cmake gcc libudev-devel \
     libnl3-devel pkg-config \
     valgrind python3-devel python3-docutils \
     flex bison openssl-devel unzip dwarves \
     elfutils-devel python3-pip python3-pyelftools meson dwarves libpcap-devel \
     tar wget dos2unix psmisc "kernel-devel-$(uname -r)" \
     librdmacm-devel libmnl-devel kernel-modules-extra numactl-devel \
     kernel-headers elfutils-libelf-devel ninja-build libbpf-devel
     assert_success
else
    echo "unsupported os, exiting..."
    exit 1;
fi
mkdir -p /tmp/linux && cd /tmp/linux || { echo "error: could not cd to /tmp/linux"; exit 1; }
LINUX_SOURCE_FOLDER="./linux"
# pick Linux repo and tag to build, 6.4 release has all the vpci and mana bits.
if [[ -n "$TAR_URL" ]]; then
    TAR_FILE_NAME=$(basename "$TAR_URL")
    
    ((RETRIES=0))
    # shellcheck disable=SC2015
    if [[ "$TAR_URL" != "$TAR_FILE_NAME" ]]; then
        while ! wget --tries=50 "$TAR_URL"; do
            ((RETRIES+=1))
            if [[ RETRIES -ge 10 ]]; then
                echo "Could not download $TAR_URL" 2>&1;
                exit 1;
            fi
            sleep 5
        done
    fi

    tar xzvf "$TAR_FILE_NAME" > /dev/null || {
        echo "Error: could not fetch and expand tar file $TAR_FILE_NAME from $TAR_URL" 1>&2;
        exit 1;
    }
    TAR_TOP_DIR=$(tar -tzf "$TAR_FILE_NAME" | cut -f 1 -d '/' | sort | uniq)
    if  [[ $(echo "$TAR_TOP_DIR" | wc -l) -gt 1 ]]; then
        echo "Error: could not identify tar top dir" 1>&2;
        exit 1;
    fi
    LINUX_SOURCE_FOLDER="$TAR_TOP_DIR"
elif [[ -z "$GIT_REPO" ]]; then
    GIT_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
    if [[ -z "$GIT_REF" ]]; then
        GIT_REF="v6.15-rc5"
    fi
fi
if [[ -z "$TAR_URL" ]] && [[ -n "$GIT_REPO" ]]; then
    # checkout from git if needed
    git clone "$GIT_REPO" -b "$GIT_REF" --depth 1 ./linux || {
        echo "Could not clone kernel" 1>&2; exit 1;
    }
fi

sudo modprobe uio_hv_generic mana_ib
if [[ -n "$PATCH_FILE" ]]; then
    for patchfile in ${PATCH_FILE/,/ }; do
        cp "$patchfile" "$LINUX_SOURCE_FOLDER/$patchfile" || { 
            echo "could not copy patch file $patchfile to $LINUX_SOURCE_FOLDER: $?"; exit 1; 
        }
    done
fi
pushd "$LINUX_SOURCE_FOLDER" || { echo "pushd linux failed: $?"; exit 1; }
if [[ -n "$PATCH_FILE" ]]; then
    for patchfile in ${PATCH_FILE/,/ }; do
        git apply "$patchfile" || { echo "git apply failed: $?"; exit 1; }
    done
fi

readlink -f . > "$CACHE_DIR/linux-src-dir"
# something is weird with localmodconfig now. Editing the config seems to get wiped?
# just copy the old config instead.
sudo cp "/boot/config-$(uname -r)" .config
sudo -E chown "$USER" .config 
#yes "" | make oldconfig || { echo "Could not make kernel" ; exit 1; }

sed -i 's/CONFIG_SYSTEM_REVOCATION_LIST/#CONFIG_SYSTEM_REVOCATION_LIST/g' .config \
|| { echo "Config settings for CONFIG_SYSTEM_REVOCATION_LIST failed, ignoring..."; }
sed -i 's/CONFIG_SYSTEM_TRUSTED_KEYS/#CONFIG_SYSTEM_TRUSTED_KEYS/g' .config  \
|| { echo "Config settings for CONFIG_SYSTEM_TRUSTED_KEYS failed, ignoring..."; }
sed -i 's/# CONFIG_MANA_INFINIBAND is not set/CONFIG_MANA_INFINIBAND=m/g' .config \
|| { echo "Config settings for CONFIG_MANA_INFINIBAND failed, ignoring..."; }
 
#check that it's set
check_and_append .config 'CONFIG_MANA_INFINIBAND=m' \
|| { echo "Could not set CONFIG_MANA_INFINIBAND, ignoring..."; }

grep MELLANOX "/boot/config-$(uname -r)" >> .config
grep MLX4 "/boot/config-$(uname -r)" >> .config
grep MLX5 "/boot/config-$(uname -r)" >> .config

if [[ -n "$KASAN" ]]; then
    check_and_append .config 'CONFIG_KASAN=y' \
    && check_and_append .config 'CONFIG_KASAN_GENERIC=y' \
    && check_and_append .config 'CONFIG_KASAN_INLINE=y' \
    && check_and_append .config 'CONFIG_STACKTRACE=y' \
    || { echo "Could not enable KASAN!"; exit 1; }
fi

if [[ -n "$ADD_CONFIGS" ]]; then
    # add any additional configs
    IFS=',' read -ra config_options <<< "$ADD_CONFIGS"
    for config in "${config_options[@]}"; do
        if [[ -n "$config" ]]; then
            check_and_append .config "$config" || {
                echo "Could not set config $config, ignoring..."; 
            }
        fi
    done
fi

# build it and hope `make -j` doesn't kill your ssh
yes "" | make -j 32 || {
    echo "Could not build the kernel"; # exit 1;
}

sudo make -j modules_install || {
    echo "Could not build the kernel"; # exit 1;
}

sudo make -j headers_install || {
    echo "Could not build the kernel"; # exit 1;
}

sudo make -j install || {
    echo "Could not build the kernel"; # exit 1;
}
popd || { echo "popd failed?";}  # exit 1; }


## NOTE: run manually to genericize if creating an azure sig image
# sudo -s
# NOTE: sudo -s first so you can shutdown after. Your user gets wiped during deprovisioning
# waagent deprovision+user 
#### asks for 'y' ^
# shutdown now
