# dpdkhelp

here's some of my example scripts to set up and run dpdk on azure.
folder layout is important, don't scrooch stuff around.
-mm

## quick start

``` bash
git clone https://www.github.com/mcgov/dpdkhelp
cd dpdkhelp
./setup/enable_hugepages.sh
# for mana pmd:
./setup/setup-mana-pmd.sh --device eth1[,eth2…]
# for netvsc pmd:
./setup/setup-netvsc-pmd.sh --device eth1[,eth2…]
# then start testpmd
./run/run-pps-dpdk-testpmd.sh --mode txonly --tx-ip $sender_ip,$receiver_ip
```

### sender/receiver pair

From your machine, set up and run testpmd on two VMs using every nic except eth0.
Each sender port sends to the receiver ip on the same subnet. (requires DPDK >=26.11-rc1)

``` bash
./setup-cluster.sh --hosts $user@$sender,$user@$receiver --install-deps --install-dpdk
./run/run-testpmd-pair.sh --sender $user@$sender --receiver $user@$receiver [--pmd netvsc|mana] [-t 120]
```

### end-to-end

Deploy two VMs (deploy/main.bicep), install dpdk, run the sender/receiver pair, then delete the resource group.
Use `--keep` to keep the VMs afterwards, or `--keep-on-failure` to keep them only if a step fails.
An existing resource group is never deleted. Logs go to `./logs/$resource_group`.

``` bash
az login
./testpmd-pair-e2e.sh -l $region [-g $resource_group] [--vm-size Standard_D8s_v5] [--pmd netvsc|mana] [--keep]
```

To put the VMs in an availability set with extra tags or properties, export json object files before deploying:

``` bash
export AVSET_TAGS_FILE=./avset-tags.json             # ex: { "<tag>": "<value>" }
export AVSET_PROPERTIES_FILE=./avset-properties.json # ex: { "<property>": <value> }
```

## issues
contact me
