#! /bin/bash
OPTIONS="s:c:h"
LONGOPTIONS="help,size:,count:"

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
            echo "Usage: $0 -s|--size <hugepage-size> -c|--count <hugepage-count> [--help]"
            exit 0
            ;;
        -s|--size)
            hugepage_size="$2"
            shift 2
            ;;
        -c|--count)
            hugepage_count="$2"
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


if [ -z "$hugepage_size" ]; then
    hugepage_size="2M"
fi
case "$hugepage_size" in
    2M)
        
        hugepage_path="/sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages"
        [[ -n "$hugepage_count" ]] || hugepage_count=1024
        ;;
    1G)
        if ! [[ -d /dev/hugepages1G ]]; then
            mkdir /dev/hugepages1G \
            && mount -t hugetlbfs -o pagesize=1G none /dev/hugepages1G \
            || { echo "Failed to mount 1G hugepages"; exit 1; }
        fi
        hugepage_path="/sys/devices/system/node/node*/hugepages/hugepages-1048576kB/nr_hugepages"
        [[ -n "$hugepage_count" ]] || hugepage_count=1
        ;;
    *)
        echo "Unsupported hugepage size: $hugepage_size"
        exit 1
        ;;
esac

for file in $hugepage_path; do
    echo "$hugepage_count" | sudo tee "$file" || {
        echo "Failed to set hugepages count in $file"
        exit 1;
    }
done

exit 0