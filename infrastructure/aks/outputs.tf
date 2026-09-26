output "resource_group_name" {
  description = "Resource group containing the POC resources."
  value       = azurerm_resource_group.this.name
}

output "cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "node_resource_group_name" {
  description = "AKS-managed node resource group name."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "application_node_pool_name" {
  description = "Name of the user node pool reserved for CVAT workloads."
  value       = azurerm_kubernetes_cluster_node_pool.cvat.name
}

output "location" {
  description = "Azure region containing the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.location
}

output "aks_identity_id" {
  description = "Resource ID of the AKS user-assigned managed identity."
  value       = azurerm_user_assigned_identity.aks.id
}

output "effective_subnet_id" {
  description = "Subnet used by the AKS system node pool."
  value       = local.effective_subnet_id
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL used for AKS Workload Identity federation."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "get_credentials_command" {
  description = "Azure CLI command that retrieves credentials for this cluster."
  value       = "az aks get-credentials --subscription ${var.subscription_id} --resource-group ${azurerm_resource_group.this.name} --name ${azurerm_kubernetes_cluster.this.name}"
}
