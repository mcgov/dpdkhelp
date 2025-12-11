# dpdkhelp

here's some of my example scripts to set up and run dpdk on azure.
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

## issues
contact me
