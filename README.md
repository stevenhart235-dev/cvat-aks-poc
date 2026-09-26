# CVAT on AKS POC

Proof of concept for evaluating CVAT deployment requirements on Azure Kubernetes Service (AKS).

## Objectives

- Understand CVAT's Kubernetes architecture and dependencies.
- Establish a minimal reproducible AKS deployment.
- Evaluate compute, storage, networking, and identity requirements.
- Validate CPU-based CVAT workloads first.
- Evaluate GPU-backed inference separately.
- Explore storage architecture suitable for large image/video datasets.
- Capture findings that can inform a production AKS platform design.

## Approach

This repository intentionally starts with a minimal AKS baseline.

Complex enterprise concerns such as hub/spoke networking, enterprise firewall integration,
centralized observability, private connectivity, and production HA will be evaluated after
the application requirements are understood.

## Milestone 1 foundation

The Terraform root in `infrastructure/aks` creates:

- A resource group and, by default, a dedicated VNet and AKS subnet.
- A user-assigned managed identity with Network Contributor on the AKS subnet.
- A public AKS cluster using Azure CNI Overlay, Cilium, and Standard Load Balancer.
- A system-only node pool. Application and GPU pools are intentionally deferred.
- Kubernetes RBAC, OIDC issuer, Workload Identity, and Azure Disk CSI.

An existing subnet can be supplied with `external_subnet_id`. In that mode Terraform
does not create, import, or manage the external VNet or subnet, but it does create the
role assignment required by the AKS managed identity.

CVAT, ingress, GPU capacity, service mesh, private AKS, and enterprise platform tooling
are outside Milestone 1.

### Milestone 1 status

Milestone 1 was successfully deployed and validated in Azure:

- AKS is running Kubernetes 1.35.8.
- Networking uses Azure CNI Overlay with the Cilium data plane.
- OIDC issuer and Workload Identity are enabled.
- The initial node pool is reserved for system workloads.
- Azure Disk CSI and its snapshot controller are enabled.
- The node and all current `kube-system` workloads passed post-deployment health checks.
- A post-deployment Terraform plan reported zero drift.

CVAT, application node pools, and GPU capacity are intentionally deferred to later
milestones.

## Usage

1. Copy `infrastructure/aks/terraform.tfvars.example` to `terraform.tfvars` and set the
   Azure subscription ID and any desired overrides.
2. From `infrastructure/aks`, run `terraform init` and `terraform plan`.
3. Review the plan before explicitly running `terraform apply`.

`kubernetes_version` is optional. When it is unset, Azure selects an appropriate
supported version for the region. Set it only when deterministic versioning is needed.

## Validation

From `infrastructure/aks`, run:

```powershell
terraform fmt -check -recursive
terraform validate
terraform test
```
