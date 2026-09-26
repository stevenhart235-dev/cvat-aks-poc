locals {
  resource_group_name      = "rg-${var.name_prefix}"
  node_resource_group_name = "rg-${var.name_prefix}-nodes"
  cluster_name             = "aks-${var.name_prefix}"
  vnet_name                = "vnet-${var.name_prefix}"
  subnet_name              = "snet-aks"
  identity_name            = "id-${var.name_prefix}-aks"

  use_external_subnet = var.external_subnet_id != null
  external_subnet_parts = local.use_external_subnet ? regex(
    "(?i)^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\\.Network/virtualNetworks/([^/]+)/subnets/([^/]+)$",
    var.external_subnet_id
  ) : []
  effective_subnet_id = local.use_external_subnet ? var.external_subnet_id : azurerm_subnet.aks[0].id

  tags = merge({
    Project   = "cvat-aks-poc"
    ManagedBy = "Terraform"
    Purpose   = "proof-of-concept"
  }, var.tags)
}

data "azurerm_virtual_network" "external" {
  count = local.use_external_subnet ? 1 : 0

  name                = local.external_subnet_parts[2]
  resource_group_name = local.external_subnet_parts[1]
}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags

  lifecycle {
    precondition {
      condition     = !local.use_external_subnet || lower(data.azurerm_virtual_network.external[0].location) == lower(var.location)
      error_message = "The external subnet VNet and AKS cluster must be in the same Azure region."
    }
  }
}

resource "azurerm_virtual_network" "this" {
  count = local.use_external_subnet ? 0 : 1

  name                = local.vnet_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  count = local.use_external_subnet ? 0 : 1

  name                 = local.subnet_name
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this[0].name
  address_prefixes     = [var.aks_subnet_cidr]
}

resource "azurerm_user_assigned_identity" "aks" {
  name                = local.identity_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "aks_subnet_network_contributor" {
  scope                = local.effective_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = local.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = local.cluster_name

  kubernetes_version                = var.kubernetes_version
  node_resource_group               = local.node_resource_group_name
  sku_tier                          = "Free"
  private_cluster_enabled           = false
  role_based_access_control_enabled = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  local_account_disabled            = false

  default_node_pool {
    name                         = "system"
    type                         = "VirtualMachineScaleSets"
    vm_size                      = var.system_node_vm_size
    node_count                   = var.system_node_count
    auto_scaling_enabled         = false
    os_sku                       = "Ubuntu"
    os_disk_type                 = "Managed"
    os_disk_size_gb              = 64
    vnet_subnet_id               = local.effective_subnet_id
    only_critical_addons_enabled = true

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
  }

  storage_profile {
    disk_driver_enabled         = true
    file_driver_enabled         = false
    blob_driver_enabled         = false
    snapshot_controller_enabled = true
  }

  tags = local.tags

  depends_on = [azurerm_role_assignment.aks_subnet_network_contributor]
}
