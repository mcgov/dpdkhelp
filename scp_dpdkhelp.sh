#! /bin/bash

# author mamcgove at microsoft aka @mcgov on github

# copy_to_vm.sh
# helper to copy the repository without copying the .git folder or leftover .dpdkcache folders from local testing.
# usage: copy_to_vm.sh -i $key_path --user $user --ip $ip
#   or: if your username is the same and ssh key is in ~/.ssh/id_rsa:
#       copy_to_vm.sh  --ip $dest_ip


# path helpers
# should be root dir of dpdkhelp
SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
username="$USER"
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
            echo "Usage: usage: $0 [--help] [ -i \$key_path] [ --user \$user ] --ip @\$dest_ip"
            exit 0
            ;;
        -i|--key)
            ssh_key_path="$2"
            shift 2
            ;;
        -u|--user)
            username="$2"
            shift 2
            ;;
        -d|--ip)
            dest_ip="$2"
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

[[ -n "$dest_ip" ]] || {
    echo "Error: provide destination ip";
    exit 1;
}
# exit code
((failed=0))

declare -A jobs;
ssh -i "$ssh_key_path" "$username"@"$dest_ip" 'mkdir -p dpdkhelp' || {
    echo "Could not make dpdkhelp path in home dir for $username on $dest_ip";
    exit 1;
}

for thing in "$SCRIPT_DIR"/*; do
    scp -r -i "$ssh_key_path" "$thing" "$username@$dest_ip:dpdkhelp/" &
    jobs["$!"]="$thing";
done

for pid in "${!jobs[@]}"; do
    wait "$pid" || {
        echo "copy job $pid failed to copy file ${jobs[$pid]} to $username@$dest_ip!"; 
        ((failed++));
    }
done

if ((failed)); then
    echo "copy attempt failed."
    exit "$failed"
else
    echo "copied all the things from $SCRIPT_DIR to $username@$dest_ip:dpdkhelp/"
    exit 0;
fi