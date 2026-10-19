#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# run apt-get with retries, for fresh VMs and throttled mirrors.
# - waits for cloud-init to finish, it runs apt on first boot and holds the dpkg lock
# - waits for the dpkg/apt locks instead of failing immediately (unattended-upgrades)
# - retries downloads inside apt, then retries the whole command with a backoff
# usage: apt-retry.sh <apt-get args...>    ex: apt-retry.sh install -y tcpdump
# env: APT_RETRY_ATTEMPTS (default 5), APT_LOCK_TIMEOUT seconds (default 600)

ATTEMPTS="${APT_RETRY_ATTEMPTS:-5}"
LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-600}"
HOST="$(hostname)"

[[ $# -gt 0 ]] || { echo "usage: $0 <apt-get args...>"; exit 1; }

if command -v cloud-init > /dev/null; then
    timeout "$LOCK_TIMEOUT" cloud-init status --wait > /dev/null 2>&1 \
        || echo "[$HOST] Warning: cloud-init didn't report done, continuing"
fi

for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
    sudo DEBIAN_FRONTEND=noninteractive apt-get \
        -o DPkg::Lock::Timeout="$LOCK_TIMEOUT" -o Acquire::Retries=5 -o Acquire::http::Timeout=60 "$@" && exit 0
    rc=$?
    echo "[$HOST] apt-get $* failed with $rc (attempt $attempt/$ATTEMPTS)"
    ((attempt < ATTEMPTS)) && sleep $((attempt * 15))
done
echo "[$HOST] Error: apt-get $* failed after $ATTEMPTS attempts"
exit 1
