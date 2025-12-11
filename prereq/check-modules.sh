#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github
# check the environment and verify if the minimum requirements for DPDK and mana are available
modules_needed=( mana mana_ib uio_hv_generic )

declare -A config_names;
declare -A module_config;
declare -A module_loaded;
declare -A shared_module_paths;

config_names["mana"]="CONFIG_MICROSOFT_MANA"
config_names["mana_ib"]="CONFIG_MANA_INFINIBAND"
config_names["uio_hv_generic"]="CONFIG_UIO_HV_GENERIC"

driver_ko_path="/lib/modules/$(uname -r)/kernel/drivers"
shared_module_paths["mana"]=net/ethernet
shared_module_paths["mana_ib"]=infiniband/hw
shared_module_paths["mana"]=uio

((failed=0));

# check kernel config
# shellcheck disable=SC2015
for module in "${modules_needed[@]}"; do
    module_config["$module"]=$( cat /boot/config-"$(uname -r)" | grep -x "^${config_names["$module"]}=[my]" ) \
    && { 
        echo "INFO: $module config found: ${module_config["$module"]}";
    } || { 
        echo "WARNING: $module config ${config_names["$module"]} not enabled in /boot/config-$(uname -r)" 1>&2 ;
    }
done

# check for drivers that are loaded (possibly built-in)
# TODO : try load if missing?
for module in "${modules_needed[@]}"; do
    if [[ -d "/sys/module/$module" ]]; then \
        module_loaded["$module"]="true";
        echo "INFO: $module is loaded"
    else
        module_loaded["$module"]="";
        echo "WARNING: $module is not loaded" 1>&2
    fi
done

# check for drivers that are shared modules are maybe aren't loaded

for module in "${modules_needed[@]}"; do
    [[ -n "${module_loaded["$module"]}" ]] \
    || [[ -d "$driver_ko_path/${shared_module_paths["$module"]}/$module" ]] \
    || {
        echo "ERROR: $module is not available, neither built-in nor as a loadable shared module." 1>&2
        ((failed++));
    }
done

# net/ethernet/mana
# net/hyperv/hv_netvsc
# uio/uio_hv_generic
# infiniband/hw/mana_ib

