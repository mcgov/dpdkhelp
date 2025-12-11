#! /bin/bash

# quick setup for a cluster
SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
ssh_key_path="$HOME/.ssh/id_rsa"
OPTIONS="i:u:d"
LONGOPTIONS="key:,user:,ip:,help"
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
            echo "Usage: usage: $0 [--help] [ -i \$key_path] [ --user \$user ] --hosts user@host[,user@host2,user2@host3,...]"
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
"$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- 'dpdkhelp/install/setup/enable-build-deps.sh && dpdkhelp/install/setup/install-build-deps.sh' || exit 1;
"$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- dpdkhelp/install/rdma/get-rdma-core-tar.sh || exit 1;
# shellcheck disable=SC2016
"$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- 'cd rdma-core-58.0 && $HOME/dpdkhelp/install/rdma/install-rdma-core.sh' || exit 1;
"$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- 'sudo reboot' || exit 1;
echo "waiting for reboot..."
sleep 30
until "$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- 'echo cool'; do
	sleep 1;
done
"$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- 'dpdkhelp/install/dpdk/get-dpdk-git.sh --ref v25.03' || exit 1;
# shellcheck disable=SC2016
"$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- 'cd ./dpdk && $HOME/dpdkhelp/install/dpdk/install-dpdk.sh' || exit 1;
"$SCRIPT_DIR/mssh" -i "$ssh_key_path" --hosts "$hosts" -- 'dpdkhelp/setup/enable-hugepages.sh' || exit 1;

exit 0