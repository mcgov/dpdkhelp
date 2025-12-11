#! /bin/bash
# author: mamcgove@microsoft.com aka @mcgov on github

source /etc/os-release
# shout out to debian for enabling these by default
[[ "$ID" == "debian" ]] && exit 0;
# check that we're at least on a debian like platform
[[ "$ID_LIKE" != "debian" ]] && exit 1;
# check that we're on an ubuntu-like with a codename
[[ -n "$UBUNTU_CODENAME" ]] || exit 1;

# ok let's get messy
if [[ -f /etc/apt/ubuntu.sources ]]; then
    # enable deb and deb-src in 24.04 ubuntu.sources file
    sudo -E sed -i 's/Types\: deb$/Types: deb deb-src/' /etc/apt/ubuntu.sources \
    || { echo "Failed to modify /etc/apt/ubuntu.sources"; exit 1; }
elif [[ -f /etc/apt/sources.list ]] || ! [[ -f /etc/apt/ubuntu.sources ]]; then
    # enable deb-src selectively in sources.list for the older ubuntu releases
    echo "deb-src http://azure.archive.ubuntu.com/ubuntu/ $UBUNTU_CODENAME main restricted" \
    | sudo -E tee -a /etc/apt/sources.list \
    || { echo "Failed to add deb-src line to /etc/apt/sources.list"; exit 1; }
    echo "deb-src http://azure.archive.ubuntu.com/ubuntu/ $UBUNTU_CODENAME-updates main restricted" \
    | sudo -E tee -a /etc/apt/sources.list \
    || { echo "Failed to add deb-src line to /etc/apt/sources.list"; exit 1; }
    # doing this selectively instead of enabling all deb-src lines
fi

sudo -E DEBIAN_FRONTEND=noninteractive apt update -y \
|| { echo "Failed to update apt sources to enable build-deps"; exit 1; }

exit 0