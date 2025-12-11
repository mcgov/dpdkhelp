#! /bin/bash

# setup/check_versions.sh
# check for rdma-core and dpdk, then
# prompt user to install one or both in a specific order.
# author: @mcgov on github ( mamcgove@microsoft.com )


((failed=0))
declare -A version_checks;
# bash associative array ^


# check dpdk and rdma-core versions
for library in libdpdk libibverbs; do
    # record the library version and prompt if one couldn't be found
    version_checks["$library"]=$(pkg-config --modversion "$library") || {
        echo "Could not find library version for $library!";
        ((failed++)); # <- note this specific last semi-colon ( footnote #1 )
    }
done

# if something is missing...
if [[ $failed -ne 0 ]]; then
    echo "Missing libraries for either rdma-core or dpdk. Checking which is missing..."
    # prompt to fix it
    if [[ -z "${version_checks[libibverbs]}" ]]; then
        echo "rdma core is missing, must install a recent-ish version before installing dpdk."
    fi

    if [[ -z "${version_checks[libdpdk]}" ]]; then
        echo "dpdk is missing, must install dpdk."
    fi
fi

# otherwise print the versions
echo "Found library versions:"
for key in "${!version_checks[@]}"; do
    echo "$key: ${version_checks[$key]}"
done
echo "kernel: $(uname -r)"
echo "----"

# all done
exit $failed


# footnotes:
# 1. re: the semi colon, 
#       it's important for '|| { echo "error..." ; exit $code; }' style error handling,
#       bash can't parse the statement within the locally-scoped command grouping '{}' without it.
#        ...
#       bash is weird, and this is the best style I've found 
#       for explicit and readable error handling. 
#       co-pilot can often help write the error message for you, which is nice.
