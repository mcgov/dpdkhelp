// SPDX-License-Identifier: MIT
// three VMs for a dpdk l3fwd test: sender -> forwarder (dpdk l3fwd as an NVA) -> receiver.
// based on the LISA verify_dpdk_l3fwd_ntttcp_tcp test topology.
//
// eth0 on every VM is on the mgmt subnet (10.0.0.0/24) with a public ip for ssh.
// data subnets come in pairs, pair p is a sender side subnet snd<p> = 10.0.(2p+1).0/24
// and a receiver side subnet rcv<p> = 10.0.(2p+2).0/24:
//   forwarder: a nic on every data subnet, ip x.x.x.4, with ip forwarding enabled
//   sender:    a nic on each snd<p> subnet, ip x.x.x.5
//   receiver:  a nic on each rcv<p> subnet, ip x.x.x.6
// each data subnet has a route table sending traffic for its paired subnet to the forwarder
// nic on that subnet, so the sender can't reach the receiver without going through l3fwd.
// the guest side routes are added by setup/l3fwd/setup-l3fwd-route.sh (see run/run-l3fwd.sh).

@description('Prefix for all resource names.')
param namePrefix string = 'l3fwd'

@description('Region for all resources.')
param location string = resourceGroup().location

@description('VM size for the sender and receiver, must support accelerated networking and 1 + subnetPairs nics.')
param vmSize string = 'Standard_D8s_v5'

@description('VM size for the forwarder, must support 1 + 2 * subnetPairs nics. Defaults to vmSize. l3fwd needs >= 8 cores.')
param forwarderVmSize string = ''

@minValue(1)
@maxValue(3)
@description('Number of sender/receiver subnet pairs. The forwarder gets 2 data nics per pair.')
param subnetPairs int = 1

@description('Enable accelerated networking on all nics.')
param enableAcceleratedNetworking bool = true

@description('VM admin username.')
param adminUsername string

@description('SSH public key for the admin user.')
param sshPublicKey string

@description('Source address prefix allowed to ssh to the VMs (priority 100 rule).')
param sshSourceAddressPrefix string = '*'

@maxLength(100)
@description('''Additional inbound NSG rules, assigned priority 101-200 in order. Each entry is a flat object:
{ "name": "allow-iperf", "destinationPortRange": "5201", "protocol": "Tcp", "sourceAddressPrefix": "1.2.3.4/32" }
Any securityRule property can be set; protocol, ports and address prefixes default to "*",
access defaults to "Allow" and direction to "Inbound". priority is always overridden.''')
param nsgRules array = []

@description('Tags for the availability set. The availability set is only created if this or availabilitySetProperties is not empty.')
param availabilitySetTags object = {}

@description('''Extra availability set properties, merged over the defaults (fault domains from availabilitySetFaultDomains, 5 update domains).
Passed through as-is.''')
param availabilitySetProperties object = {}

@description('Fault domain count for the availability set.')
param availabilitySetFaultDomains int = 2

@description('OS image for the VMs.')
param imageReference object = {
  publisher: 'Canonical'
  offer: 'ubuntu-24_04-lts'
  sku: 'server'
  version: 'latest'
}

var vnetName = '${namePrefix}-vnet'
var dataSubnetCount = 2 * subnetPairs
// subnet k is 10.0.k.0/24: 0 is mgmt, odd k are sender side, even k are receiver side
var subnetNames = [for k in range(0, 1 + dataSubnetCount): k == 0 ? 'mgmt' : (k % 2 == 1 ? 'snd${(k - 1) / 2}' : 'rcv${(k - 2) / 2}')]
var forwarderHost = 4
var useAvailabilitySet = !empty(availabilitySetTags) || !empty(availabilitySetProperties)

// one entry per vm, nics for vm i are nicSpecs[firstNic, firstNic + nicCount)
var vmSpecs = [
  { role: 'fwd', size: empty(forwarderVmSize) ? vmSize : forwarderVmSize, firstNic: 0, nicCount: 1 + dataSubnetCount }
  { role: 'snd', size: vmSize, firstNic: 1 + dataSubnetCount, nicCount: 1 + subnetPairs }
  { role: 'rcv', size: vmSize, firstNic: 2 + dataSubnetCount + subnetPairs, nicCount: 1 + subnetPairs }
]
var fwdNics = [for k in range(0, 1 + dataSubnetCount): { vm: 0, idx: k, subnet: k, host: forwarderHost, ipForwarding: k > 0 }]
var sndNics = [for i in range(0, 1 + subnetPairs): { vm: 1, idx: i, subnet: i == 0 ? 0 : 2 * i - 1, host: 5, ipForwarding: false }]
var rcvNics = [for i in range(0, 1 + subnetPairs): { vm: 2, idx: i, subnet: i == 0 ? 0 : 2 * i, host: 6, ipForwarding: false }]
var nicSpecs = concat(fwdNics, sndNics, rcvNics)

var sshRule = {
  name: 'allow-ssh'
  properties: {
    priority: 100
    protocol: 'Tcp'
    access: 'Allow'
    direction: 'Inbound'
    sourceAddressPrefix: sshSourceAddressPrefix
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '22'
  }
}

// convert the flat rule objects to securityRules, only defaulting the singular
// prefix/range properties when the plural form wasn't given (they're mutually exclusive)
var extraRules = [for (rule, i) in nsgRules: {
  name: rule.name
  properties: union(
    { protocol: '*', access: 'Allow', direction: 'Inbound' },
    contains(rule, 'sourceAddressPrefixes') ? {} : { sourceAddressPrefix: '*' },
    contains(rule, 'sourcePortRanges') ? {} : { sourcePortRange: '*' },
    contains(rule, 'destinationAddressPrefixes') ? {} : { destinationAddressPrefix: '*' },
    contains(rule, 'destinationPortRanges') ? {} : { destinationPortRange: '*' },
    toObject(filter(items(rule), item => item.key != 'name'), item => item.key, item => item.value),
    { priority: 101 + i }
  )
}]

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${namePrefix}-nsg'
  location: location
  properties: {
    securityRules: concat([sshRule], extraRules)
  }
}

// route table j is for data subnet k = j + 1: traffic for the paired subnet goes to the forwarder nic on subnet k
resource routeTables 'Microsoft.Network/routeTables@2023-11-01' = [for j in range(0, dataSubnetCount): {
  name: '${namePrefix}-rt-${subnetNames[j + 1]}'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'to-${subnetNames[(j + 1) % 2 == 1 ? j + 2 : j]}-via-fwd'
        properties: {
          addressPrefix: '10.0.${(j + 1) % 2 == 1 ? j + 2 : j}.0/24'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.${j + 1}.${forwarderHost}'
        }
      }
    ]
  }
}]

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [for k in range(0, 1 + dataSubnetCount): {
      name: subnetNames[k]
      properties: {
        addressPrefix: '10.0.${k}.0/24'
        networkSecurityGroup: { id: nsg.id }
        routeTable: k == 0 ? null : { id: routeTables[k - 1].id }
      }
    }]
  }
}

resource avset 'Microsoft.Compute/availabilitySets@2024-03-01' = if (useAvailabilitySet) {
  name: '${namePrefix}-avset'
  location: location
  tags: availabilitySetTags
  sku: { name: 'Aligned' }
  properties: union({
    platformFaultDomainCount: availabilitySetFaultDomains
    platformUpdateDomainCount: 5
  }, availabilitySetProperties)
}

resource pips 'Microsoft.Network/publicIPAddresses@2023-11-01' = [for spec in vmSpecs: {
  name: '${namePrefix}-${spec.role}-pip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}]

resource nics 'Microsoft.Network/networkInterfaces@2023-11-01' = [for spec in nicSpecs: {
  name: '${namePrefix}-${vmSpecs[spec.vm].role}-nic${spec.idx}'
  location: location
  properties: {
    enableAcceleratedNetworking: enableAcceleratedNetworking
    // the forwarder sends and receives traffic that isn't addressed to its own ips
    enableIPForwarding: spec.ipForwarding
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.${spec.subnet}.${spec.host}'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetNames[spec.subnet])
          }
          publicIPAddress: spec.idx == 0 ? { id: pips[spec.vm].id } : null
        }
      }
    ]
  }
  dependsOn: [vnet]
}]

resource vms 'Microsoft.Compute/virtualMachines@2024-03-01' = [for spec in vmSpecs: {
  name: '${namePrefix}-${spec.role}'
  location: location
  properties: {
    hardwareProfile: { vmSize: spec.size }
    availabilitySet: useAvailabilitySet ? { id: avset.id } : null
    storageProfile: {
      imageReference: imageReference
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }
    osProfile: {
      computerName: '${namePrefix}-${spec.role}'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [for k in range(0, spec.nicCount): {
        id: nics[spec.firstNic + k].id
        properties: {
          primary: k == 0
          deleteOption: 'Delete'
        }
      }]
    }
  }
}]

output publicIps array = [for i in range(0, 3): pips[i].properties.ipAddress]
// vm names end with -fwd, -snd and -rcv
output vmAddresses array = [for i in range(0, 3): '${vms[i].name}=${pips[i].properties.ipAddress}']
output subnetPairs array = [for p in range(0, subnetPairs): '10.0.${2 * p + 1}.0/24<->10.0.${2 * p + 2}.0/24']
