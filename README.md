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

## Proven Milestone 3 platform

The Terraform root in `infrastructure/aks` creates:

- A resource group and, by default, a dedicated VNet and AKS subnet.
- A user-assigned managed identity with Network Contributor on the AKS subnet.
- A public AKS cluster using Azure CNI Overlay, Cilium, and Standard Load Balancer.
- One fixed `Standard_D2as_v7` system node reserved for critical add-ons.
- Two fixed `Standard_D4as_v7` CVAT application nodes labeled `workload=cvat` and
  tainted `workload=cvat:NoSchedule`.
- Kubernetes RBAC, OIDC issuer, Workload Identity, Azure Disk CSI, and Azure File CSI.

An existing subnet can be supplied with `external_subnet_id`. In that mode Terraform
does not create, import, or manage the external VNet or subnet, but it does create the
role assignment required by the AKS managed identity.

This topology requires 10 regional vCPUs and 10 Dasv7-family vCPUs: two for the system
node and eight for the CVAT nodes. The proven subscription was therefore fully saturated
and had no capacity for scale-out or surge nodes.

The platform StorageClasses are Kubernetes resources deliberately managed outside
Terraform:

- `cvat-rwx` uses Azure Files CSI for shared `ReadWriteMany` storage.
- `cvat-rwo` uses Azure Disk CSI for `ReadWriteOnce` stateful storage.

CVAT itself, ingress, GPU capacity, service mesh, private AKS, and enterprise platform
tooling have not been deployed.

### Milestone 1 status

Milestone 1 was successfully deployed and validated in Azure before teardown:

- At validation time, AKS ran Kubernetes 1.35.8.
- Networking uses Azure CNI Overlay with the Cilium data plane.
- OIDC issuer and Workload Identity are enabled.
- The initial node pool is reserved for system workloads.
- Azure Disk CSI and its snapshot controller are enabled.
- The node and all current `kube-system` workloads passed post-deployment health checks.
- A post-deployment Terraform plan reported zero drift.

Milestone 3 subsequently added and validated the dedicated application pool, Azure File
CSI, and both platform StorageClasses. Cross-node RWX access and same-node RWO persistence
across pod recreation passed. See [docs/milestone-3-plan.md](docs/milestone-3-plan.md) for
the measured evidence.

## Recreation and validation runbook

### Prerequisites

- Terraform compatible with the committed provider lock file.
- Azure CLI authenticated to a subscription where the required resource providers are
  registered.
- `kubectl` and PowerShell 7.
- At least 10 available regional vCPUs and 10 available Dasv7-family vCPUs in `eastus2`.
- Permission to create the documented Azure resources and subnet role assignment.

### Deploy

1. Authenticate and explicitly select the intended Azure subscription:

   ```powershell
   az login
   az account set --subscription <subscription-id-or-name>
   az account show --query "{name:name,id:id,tenantId:tenantId}" -o json
   ```

2. Copy `infrastructure/aks/terraform.tfvars.example` to the ignored local file
   `infrastructure/aks/terraform.tfvars`, then set `subscription_id` and any deliberate
   overrides. Confirm the selected Azure CLI subscription matches this value.

3. Initialize, review, and apply Terraform from `infrastructure/aks`:

   ```powershell
   terraform init
   terraform plan -out cvat-aks-poc.tfplan
   terraform apply cvat-aks-poc.tfplan
   ```

4. Obtain credentials using the `get_credentials_command` Terraform output, then verify
   the context and nodes:

   ```powershell
   terraform output -raw get_credentials_command
   kubectl config current-context
   kubectl get nodes -o wide
   ```

5. From the repository root, apply the platform StorageClasses and run validation:

   ```powershell
   kubectl apply -f kubernetes/platform/storage-classes.yaml
   ./scripts/validate-storage.ps1
   ```

6. Cleanup is mandatory after every storage validation because both platform
   StorageClasses use `Retain`. Run cleanup immediately and confirm the test namespace,
   PVCs, PVs, managed disk, file share, and any test-created empty storage account are
   gone:

   ```powershell
   ./scripts/cleanup-storage-validation.ps1
   kubectl get storageclass cvat-rwx cvat-rwo
   kubectl get namespace cvat-storage-validation --ignore-not-found
   terraform -chdir=infrastructure/aks plan -detailed-exitcode
   ```

### Tear down

When the POC session is finished, review the complete destroy scope before approving it:

```powershell
terraform -chdir=infrastructure/aks plan -destroy
terraform -chdir=infrastructure/aks destroy
terraform -chdir=infrastructure/aks state list
```

The final state listing should be empty. Verify both the primary and AKS-managed node
resource groups are gone.

## Terraform behavior

`kubernetes_version` is optional. When it is unset, Azure selects an appropriate
supported version for the region. Set it only when deterministic versioning is needed.

## Validation

From `infrastructure/aks`, run:

```powershell
terraform fmt -check -recursive
terraform validate
terraform test
```
