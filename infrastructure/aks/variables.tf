variable "subscription_id" {
  description = "Azure subscription in which the POC resources will be created."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a valid UUID."
  }
}

variable "location" {
  description = "Azure region for the POC resources."
  type        = string
  default     = "eastus2"
}

variable "name_prefix" {
  description = "Short lowercase prefix used to name POC resources."
  type        = string
  default     = "cvat-poc"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-32 lowercase letters, numbers, or hyphens and cannot begin or end with a hyphen."
  }
}

variable "kubernetes_version" {
  description = "Optional AKS Kubernetes version. Null lets Azure select a supported version for the region."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.kubernetes_version == null || can(regex("^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$", var.kubernetes_version))
    error_message = "kubernetes_version must be null or a version such as 1.32 or 1.32.5."
  }
}

variable "system_node_vm_size" {
  description = "VM size for the AKS system node pool."
  type        = string
  default     = "Standard_D2as_v7"
}

variable "system_node_count" {
  description = "Fixed node count for the initial system node pool."
  type        = number
  default     = 1

  validation {
    condition     = var.system_node_count >= 1 && floor(var.system_node_count) == var.system_node_count
    error_message = "system_node_count must be a positive whole number."
  }
}

variable "vnet_cidr" {
  description = "Address space for the standalone POC VNet."
  type        = string
  default     = "10.20.0.0/16"
}

variable "aks_subnet_cidr" {
  description = "Address prefix for the standalone AKS subnet."
  type        = string
  default     = "10.20.0.0/22"
}

variable "pod_cidr" {
  description = "Pod address space used by Azure CNI Overlay."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes service address space."
  type        = string
  default     = "10.2.0.0/16"
}

variable "dns_service_ip" {
  description = "CoreDNS IP within the Kubernetes service address space."
  type        = string
  default     = "10.2.0.10"
}

variable "external_subnet_id" {
  description = "Optional existing subnet ARM ID. When set, Terraform does not create or manage a VNet or subnet."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.external_subnet_id == null || can(regex(
      "(?i)^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/resourceGroups/[^/\\s]+/providers/Microsoft\\.Network/virtualNetworks/[^/\\s]+/subnets/[^/\\s]+$",
      var.external_subnet_id
    ))
    error_message = "external_subnet_id must be null or a complete subnet ARM ID without whitespace or a trailing slash."
  }

  validation {
    condition     = var.external_subnet_id == null || try(lower(split("/", var.external_subnet_id)[2]) == lower(var.subscription_id), false)
    error_message = "The external subnet must be in subscription_id. Cross-subscription networking is outside this POC."
  }
}

variable "tags" {
  description = "Additional tags to apply to taggable resources."
  type        = map(string)
  default     = {}
}
