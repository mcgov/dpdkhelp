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
./run/run-testpmd-pair.sh --sender $user@$sender --receiver $user@$receiver [--pmd auto|netvsc|mana] [-t 120]
```

### end-to-end

Deploy two VMs (deploy/main.bicep), install dpdk, run the sender/receiver pair, then delete the resource group.
Use `--keep` to keep the VMs afterwards, or `--keep-on-failure` to keep them only if a step fails.
An existing resource group is never deleted. Logs go to `./logs/$resource_group`.

``` bash
az login
./testpmd-pair-e2e.sh -l $region [-g $resource_group] [--vm-size Standard_D8s_v5] [--pmd auto|netvsc|mana] [--keep]
```

To put the VMs in an availability set with extra tags or properties, export json object files before deploying:

``` bash
export AVSET_TAGS_FILE=./avset-tags.json             # ex: { "<tag>": "<value>" }
export AVSET_PROPERTIES_FILE=./avset-properties.json # ex: { "<property>": <value> }
```

### l3fwd

Run dpdk-l3fwd on a forwarder VM between a sender and receiver on different subnets, with ntttcp for traffic
(based on the LISA `verify_dpdk_l3fwd_ntttcp_tcp` test). eth0 is left alone on every VM for ssh.
deploy/l3fwd.bicep creates the VMs, subnet pairs (`10.0.1.0/24`<->`10.0.2.0/24`, `10.0.3.0/24`<->`10.0.4.0/24`, ...),
ip forwarding on the forwarder nics, and the azure route tables that send each pair's traffic through the forwarder.
run/run-l3fwd.sh adds the matching routes and neighbor entries on the sender/receiver
(setup/l3fwd/setup-l3fwd-route.sh), then starts l3fwd (run/run-dpdk-l3fwd.sh) and ntttcp on every subnet pair.
Before l3fwd starts it checks that the sender and receiver can't ping each other on the test subnets,
the run fails if traffic can get around the forwarder.

``` bash
./deploy/deploy.sh -g $resource_group -l $region --template l3fwd [--param subnetPairs=2 --param forwarderVmSize=Standard_D16s_v5]
./setup-cluster.sh --hosts $user@$forwarder,$user@$sender,$user@$receiver --install-deps --install-dpdk
./run/run-l3fwd.sh --forwarder $user@$forwarder --sender $user@$sender --receiver $user@$receiver [--pmd auto|netvsc|mana] [-t 30]
# or all of it, end-to-end:
./l3fwd-e2e.sh -l $region [-g $resource_group] [--subnet-pairs 2 --forwarder-vm-size Standard_D16s_v5] [--keep]
```

The forwarder needs 1 + 2 * subnet pairs nics, Standard_D8s_v5 supports 4 (1 pair).

## issues
contact me
