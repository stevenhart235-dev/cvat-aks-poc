# Milestone 1: AKS foundation

Milestone 1 established and validated the standalone AKS foundation needed to evaluate
CVAT without introducing application or enterprise-platform concerns prematurely.

## Deployed architecture

- Public AKS cluster running Kubernetes 1.35.8 in Azure's Free tier.
- Dedicated resource group, VNet, and AKS subnet, with optional support for an externally
  owned subnet.
- Azure CNI Overlay with the AKS-managed Cilium data plane and Standard Load Balancer.
- User-assigned cluster identity with Network Contributor on the AKS subnet.
- Kubernetes RBAC, OIDC issuer, and Workload Identity enabled.
- One fixed system node using `Standard_D2as_v7`, protected by the
  `CriticalAddonsOnly=true:NoSchedule` taint.
- Azure Disk CSI and snapshot controller enabled; Azure File and Blob CSI disabled.

## Validation result

- The node reached `Ready` on Kubernetes 1.35.8.
- Cilium reported healthy and had one Ready agent per node.
- CoreDNS, Metrics Server, Workload Identity, Azure networking, and connectivity
  components were Running and Ready.
- The Azure Disk CSI node plugin was Ready, its driver was registered, and the expected
  managed-disk storage classes were present.
- Initial bootstrap-order warnings converged without intervention; no unhealthy
  `kube-system` workloads remained.
- A post-deployment Terraform plan reported no changes.

## Deliberate boundaries

The cluster currently has no CVAT deployment, application node pool, GPU node pool,
service mesh, private API, or enterprise observability and security integrations. These
will be evaluated only as later milestones require them.
