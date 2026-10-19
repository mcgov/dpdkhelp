// SPDX-License-Identifier: MIT
// two (or more) VMs for dpdk testing: eth0 for management/ssh with a public ip,
// plus data nics on their own subnets (10.0.1.0/24, 10.0.2.0/24, ...) with accelerated networking.

@description('Prefix for all resource names.')
param namePrefix string = 'dpdk'

@description('Region for all resources.')
param location string = resourceGroup().location

@description('VM size, must support accelerated networking and 1 + dataNicCount nics.')
param vmSize string = 'Standard_D8s_v5'

@minValue(1)
@description('Number of VMs to deploy.')
param vmCount int = 2

@minValue(0)
@maxValue(7)
@description('Number of data nics per VM (in addition to eth0).')
param dataNicCount int = 2

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

var nicsPerVm = 1 + dataNicCount
var vnetName = '${namePrefix}-vnet'
var subnetNames = [for k in range(0, nicsPerVm): k == 0 ? 'mgmt' : 'data${k}']
var useAvailabilitySet = !empty(availabilitySetTags) || !empty(availabilitySetProperties)

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

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [for k in range(0, nicsPerVm): {
      name: subnetNames[k]
      properties: {
        addressPrefix: '10.0.${k}.0/24'
        networkSecurityGroup: { id: nsg.id }
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

resource pips 'Microsoft.Network/publicIPAddresses@2023-11-01' = [for i in range(0, vmCount): {
  name: '${namePrefix}-vm${i}-pip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}]

// flattened vm x nic loop: nic k of vm i is index i * nicsPerVm + k, nic 0 is eth0
resource nics 'Microsoft.Network/networkInterfaces@2023-11-01' = [for j in range(0, vmCount * nicsPerVm): {
  name: '${namePrefix}-vm${j / nicsPerVm}-nic${j % nicsPerVm}'
  location: location
  properties: {
    enableAcceleratedNetworking: enableAcceleratedNetworking
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetNames[j % nicsPerVm])
          }
          publicIPAddress: j % nicsPerVm == 0 ? { id: pips[j / nicsPerVm].id } : null
        }
      }
    ]
  }
  dependsOn: [vnet]
}]

resource vms 'Microsoft.Compute/virtualMachines@2024-03-01' = [for i in range(0, vmCount): {
  name: '${namePrefix}-vm${i}'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
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
      computerName: '${namePrefix}-vm${i}'
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
      networkInterfaces: [for k in range(0, nicsPerVm): {
        id: nics[i * nicsPerVm + k].id
        properties: {
          primary: k == 0
          deleteOption: 'Delete'
        }
      }]
    }
  }
}]

output publicIps array = [for i in range(0, vmCount): pips[i].properties.ipAddress]
output vmAddresses array = [for i in range(0, vmCount): '${vms[i].name}=${pips[i].properties.ipAddress}']
output dataSubnets array = [for k in range(1, dataNicCount): '10.0.${k}.0/24']
