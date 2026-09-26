mock_provider "azurerm" {
  mock_data "azurerm_virtual_network" {
    defaults = {
      location = "centralus"
    }
  }

  mock_resource "azurerm_subnet" {
    override_during = plan

    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-cvat-poc/providers/Microsoft.Network/virtualNetworks/vnet-cvat-poc/subnets/snet-aks"
    }
  }

  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-cvat-poc/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-cvat-poc-aks"
      principal_id = "11111111-1111-1111-1111-111111111111"
    }
  }
}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
}

run "standalone_foundation" {
  command = plan

  assert {
    condition     = length(azurerm_virtual_network.this) == 1 && length(azurerm_subnet.aks) == 1
    error_message = "Standalone mode must create one VNet and one AKS subnet."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].vnet_subnet_id == azurerm_subnet.aks[0].id
    error_message = "The system pool must use the standalone subnet."
  }

  assert {
    condition     = azurerm_role_assignment.aks_subnet_network_contributor.scope == azurerm_subnet.aks[0].id
    error_message = "The AKS identity role assignment must target the standalone subnet."
  }
}

run "aks_baseline" {
  command = plan

  assert {
    condition     = var.kubernetes_version == null
    error_message = "Kubernetes version must remain optional by default."
  }

  assert {
    condition     = !azurerm_kubernetes_cluster.this.private_cluster_enabled && azurerm_kubernetes_cluster.this.role_based_access_control_enabled
    error_message = "Milestone 1 requires a public API and Kubernetes RBAC."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.oidc_issuer_enabled && azurerm_kubernetes_cluster.this.workload_identity_enabled
    error_message = "OIDC issuer and Workload Identity must be enabled."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].network_plugin == "azure" && azurerm_kubernetes_cluster.this.network_profile[0].network_plugin_mode == "overlay" && azurerm_kubernetes_cluster.this.network_profile[0].network_data_plane == "cilium"
    error_message = "AKS must use Azure CNI Overlay with the Cilium data plane."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].load_balancer_sku == "standard" && azurerm_kubernetes_cluster.this.network_profile[0].outbound_type == "loadBalancer"
    error_message = "AKS must use Standard Load Balancer outbound."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].name == "system" && azurerm_kubernetes_cluster.this.default_node_pool[0].only_critical_addons_enabled
    error_message = "The initial node pool must be reserved for system workloads."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.storage_profile[0].disk_driver_enabled
    error_message = "Azure Disk CSI must be enabled."
  }
}

run "explicit_kubernetes_version" {
  command = plan

  variables {
    kubernetes_version = "1.32.5"
  }

  assert {
    condition     = var.kubernetes_version == "1.32.5"
    error_message = "An explicitly supplied Kubernetes version must be passed to AKS."
  }
}

run "external_subnet" {
  command = plan

  variables {
    location           = "centralus"
    external_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-poc/subnets/snet-aks"
  }

  assert {
    condition     = length(azurerm_virtual_network.this) == 0 && length(azurerm_subnet.aks) == 0
    error_message = "External-subnet mode must not create or manage network resources."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].vnet_subnet_id == var.external_subnet_id && azurerm_role_assignment.aks_subnet_network_contributor.scope == var.external_subnet_id
    error_message = "AKS and its role assignment must use the supplied external subnet."
  }
}

run "malformed_external_subnet_rejected" {
  command = plan

  variables {
    external_subnet_id = "/subscriptions/not-a-subnet"
  }

  expect_failures = [var.external_subnet_id]
}

run "cross_subscription_subnet_rejected" {
  command = plan

  variables {
    external_subnet_id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-poc/subnets/snet-aks"
  }

  expect_failures = [var.external_subnet_id]
}

run "external_subnet_region_mismatch_rejected" {
  command = plan

  variables {
    location           = "eastus2"
    external_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-poc/subnets/snet-aks"
  }

  expect_failures = [azurerm_resource_group.this]
}
