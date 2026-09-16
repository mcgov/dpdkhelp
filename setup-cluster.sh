#! /bin/bash
# SPDX-License-Identifier: MIT
# quick setup for a cluster
SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
ssh_key_path="$HOME/.ssh/id_rsa"
OPTIONS="i:u:d"
LONGOPTIONS="key:,hosts:,install-dpdk,install-rdma-core,help,install-deps,install-kernel"
# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    exit 2
fi
eval set -- "$PARSED"
# Process the options
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: usage: $0 [--help] [ -i \$key_path] --hosts user@host[,user@host2,user2@host3,...] [--install-dpdk] [--install-rdma-core]"
            exit 0
            ;;
        -i|--key)
            ssh_key_path="$2"
            shift 2
            ;;
        --hosts)
            hosts="$2"
            shift 2
            ;;
        --install-rdma-core)
            INSTALL_RDMA_CORE="true"
            shift
            ;;
        --install-deps)
            INSTALL_DEPS="true"
            shift
            ;;
        --install-kernel)
            INSTALL_KERNEL="true"
            shift
            ;;
        --install-dpdk)
            INSTALL_DPDK="true"
            shift
            ;;
        --)
            break
            ;;
        *)
            echo "unrecognized argument: $1"
            exit 1
            ;;
    esac
done
[[ -n "$hosts" ]] || { echo "Error, provide --hosts argument"; exit 1; }

# set some defaults but allow override via env
[[ -z "$RDMA_VERSION" ]] && RDMA_VERSION="59.0"
[[ -z "$DPDK_VERSION" ]] && DPDK_VERSION="for-main"

IFS=',' read -r -a hosts_array <<< "$hosts"
for host in "${hosts_array[@]}"; do 
    IFS='@' read -r -a addr_info <<< "$host";
    ssh-keygen -R "${addr_info[1]}" || true;
    ssh -o StrictHostKeyChecking=accept-new "$host" 'true' || { wait;  echo "Could not connect to $host, exiting...";  exit 1; }
    "$SCRIPT_DIR"/scp-dpdkhelp.sh -i "$ssh_key_path" --ip "${addr_info[1]}" --user "${addr_info[0]}" &
    pids+=( "$!" )
done
for pid in "${pids[@]}"; do
    wait "$pid" || { wait; echo "ssh $pid failed" ; exit 1; }
done;

if [[ -n "$INSTALL_DEPS" ]]; then
    "$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- 'dpdkhelp/install/setup/enable-build-deps.sh && dpdkhelp/install/setup/install-build-deps.sh' || {
        echo "could not enable build-deps."; exit 1;
    }
fi

if [[ -n "$INSTALL_KERNEL" ]]; then
    [[ -n "$LINUX_REPO" ]] || LINUX_REPO="https://github.com/torvalds/linux.git"
    [[ -n "$LINUX_REF" ]]  || LINUX_REF="v7.3-rc3"

    "$SCRIPT_DIR"/mssh --hosts "$hosts" -- dpdkhelp/install/linux/kernel-install.sh --git "$LINUX_REPO" --ref "$LINUX_REF"
fi

[[ -n "$INSTALL_RDMA_CORE" ]] && {

    "$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- dpdkhelp/install/rdma/get-rdma-core-tar.sh || {
        echo "could not fetch rdma-core source."; exit 1;
    }

    # shellcheck disable=SC2016
    "$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- \
        "cd \$(cat dpdkhelp/install/.dpdkcache/rdma_src_dir) && RDMA_VERSION='$RDMA_VERSION' ../dpdkhelp/install/rdma/install-rdma-core.sh" || {
        echo "could not install rdma-core."; exit 1;
    }
    "$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- 'sudo reboot' ;
    echo "waiting for reboot..."ho
    sleep 10 ;
}
until "$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- 'true' 2> /dev/null; do
	sleep 1;
done

[[ -n "$INSTALL_DPDK" ]] && {
    [[ -n "$DPDK_GIT" ]] || DPDK_GIT="git://dpdk.org/next/dpdk-next-net"
    [[ -n "$DPDK_VERSION" ]] || DPDK_VERSION="for-main"
    if "$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- pkg-config --modversion libdpdk \
        &&  "$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" --  bash -c "test -d ./dpdk/build"; then
         "$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- "cd dpdk/build && ninja && sudo ninja install";
    else
        "$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- "dpdkhelp/install/dpdk/get-dpdk-git.sh --ref $DPDK_VERSION --git $DPDK_GIT" || {
            echo "could not fetch dpdk source."; exit 1;
        }
        # shellcheck disable=SC2016
        "$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- 'cd ./dpdk && $HOME/dpdkhelp/install/dpdk/install-dpdk.sh' || {
            echo "could not install dpdk"; exit 1;
        }
    fi
    
    [[ $? == 0 ]] || {
        echo "DPDK build/rebuild failed."
        exit 1;
    }
    
    echo "installed dpdk...";
}

"$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- 'dpdkhelp/setup/enable-hugepages.sh' || {
    echo "could not enable hugepages."; exit 1;
}
 
echo "hooray. dpdk is now set up on hosts: $hosts"
echo "reminder: run dpdkhelp/setup/setup-[pmd type]-pmd.sh --device [eth nic names] before starting dpdk."

exit 0
