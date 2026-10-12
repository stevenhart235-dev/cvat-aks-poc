# CVAT on AKS POC handoff

## 1. Executive Summary

This repository is a completed personal Azure proof of concept for discovering the
application and platform requirements of CVAT Community on AKS. It established a
reproducible CPU platform, basic persistent-storage behavior, successful CVAT startup,
and browser login. Representative media workflows and production architecture remain
unvalidated. Completion of the POC does not mean completion of every proposed M4b
functional success criterion.

The environment was subsequently torn down. Do not assume that the original Azure
environment, credentials, local artifacts, or Kubernetes context exists in the receiving
environment. No cloud access or deployment is authorized by this handoff.

Read `docs/milestone-4a-offline-render.md`, especially its later live-failure and
recreation sections, before using the deployment configuration. The critical findings
are that CVAT needs more than an RWX access-mode declaration, its Django signing key
must be supplied consistently, and its frontend and API need a working shared browser
origin. Azure Files remains a candidate for bulk data, pending functional testing.

Evidence precedence matters: `README.md` primarily describes the proven M3 platform
and still contains an older statement that CVAT has not been deployed. Later recorded
results in `docs/milestone-4a-offline-render.md` supersede that statement. Similarly,
`docs/cvat-application-discovery.md` is historical M2 research, not the released M4
deployment baseline. Earlier proposed requirements and open questions must be read
alongside the later results rather than treated as current unfinished platform work.

## 2. Repository Structure

| Area | Exact relative paths and purpose |
| --- | --- |
| Terraform infrastructure | `infrastructure/aks/main.tf`, `variables.tf`, `providers.tf`, `versions.tf`, and `outputs.tf` under that directory; `infrastructure/aks/terraform.tfvars.example` documents inputs; `infrastructure/aks/.terraform.lock.hcl` locks the provider |
| Kubernetes storage | `kubernetes/platform/storage-classes.yaml` defines the two platform StorageClasses outside Terraform |
| Helm deployment | `helm/cvat/values-m4a-poc.yaml` contains the effective M4b scheduling, storage, resource, and Django Secret references despite its historical filename; `helm/cvat/values-m4b-secrets.example.yaml` is the non-secret schema |
| Terraform tests | `infrastructure/aks/tests/foundation.tftest.hcl` |
| Offline application tests | `scripts/tests/test-cvat-render.py`, `scripts/tests/test-cvat-secret-generation.ps1`, `scripts/tests/test-cvat-cleanup-offline.ps1`, `scripts/tests/test-cvat-local-proxy.mjs` |
| Live storage validation | `kubernetes/validation/storage/README.md`, `namespace-and-claims.yaml`, `rwx-a.yaml.tpl`, `rwx-b.yaml.tpl`, and `rwo.yaml.tpl` under that directory; `scripts/validate-storage.ps1` and `scripts/cleanup-storage-validation.ps1` |
| Local access | `docs/local-cvat-access.md` and `scripts/cvat-local-proxy.mjs` |
| Secret generation | `scripts/New-CvatM4bSecrets.ps1`; `.gitignore` excludes real local overlays and runtime artifacts |
| Application inventory and cleanup | `scripts/capture-cvat-storage-baseline.ps1`, `scripts/inventory-cvat-storage.ps1`, `scripts/cleanup-cvat.ps1`, `scripts/CvatCleanup.Common.psm1` |
| Discovery and evidence | `README.md`, `docs/milestone-1.md`, `docs/cvat-application-discovery.md`, `docs/milestone-3-plan.md`, `docs/milestone-4a-offline-render.md` |

## 3. Validated Architecture

### Platform

`infrastructure/aks/main.tf` and `infrastructure/aks/variables.tf` define a dedicated
resource group, standalone VNet/subnet, user-assigned AKS identity, subnet-scoped Network
Contributor assignment, AKS cluster, and separate application pool: seven Terraform
resources in the standalone configuration. An external same-subscription subnet can be
consumed without taking ownership of that subnet or its VNet.

The proven topology is one `Standard_D2as_v7` system node and two `Standard_D4as_v7`
user nodes. System workloads are reserved through `CriticalAddonsOnly`; CVAT nodes have
label `workload=cvat` and taint `workload=cvat:NoSchedule`. Helm affinity/node selectors
and tolerations target the application pool. Node counts are fixed, with no autoscaling,
GPU pool, or enforced application spreading.

The platform uses Azure CNI Overlay, Cilium, Standard Load Balancer outbound networking,
a public AKS API, Kubernetes RBAC, OIDC issuer, and Workload Identity. Local AKS accounts
remain enabled. Azure Disk CSI, Azure File CSI, and the snapshot controller are enabled;
Blob CSI is disabled. Enabling Workload Identity does not configure CVAT cloud-storage
authentication or create an application federated identity.

`docs/milestone-3-plan.md` records Kubernetes `1.35.8` at validation time. Terraform's
`kubernetes_version` is optional, so recreation without an explicit version does not
guarantee that historical version. The topology uses 10 regional and 10 Dasv7-family
vCPUs. The original quota left no scale-out or surge capacity; the configured 10% surge
setting is not evidence that upgrades fit within that quota.

### Released CVAT baseline

The approved artifact and dependency evidence are in `docs/milestone-4a-offline-render.md`:

| Item | Baseline |
| --- | --- |
| Application / chart | CVAT Community `v2.76.0` / chart `2.76.0` |
| Official chart reference | `oci://registry-1.docker.io/cvat/cvat` |
| OCI artifact digest | `sha256:9ce13e269106129e6f26b8e60059009a215c861a7d96bde47602ace19e71c105` |
| Chart archive SHA-256 | `fe22aa4aa47cadd25991915da8f120361131afb98f8bd005d18d13b71836f2da` |
| CVAT images | `cvat/server:v2.76.0`, `cvat/ui:v2.76.0` |
| Dependencies | Use the artifact's packaged `Chart.lock` and vendored charts without dependency updates |

The effective CVAT image tags come from the approved chart values; its metadata
`appVersion: latest` does not select those images. Container image digests were not
required for this POC. The M2 source chart `2.76.1` is historical research and must not
replace the released baseline.

The rendered baseline includes 12 Deployments, five StatefulSets, one transient
initializer Job, and 20 long-running pods with 21 long-running containers. Eleven worker
replicas cover eight worker types. Core dependencies are PostgreSQL, Redis, KVrocks,
and OPA; enabled analytics adds ClickHouse, Vector, and Grafana. Services are ClusterIP.
Ingress, Traefik, and Nuclio are disabled. The Grafana test-hook Pod is excluded from
normal operation; initial validation did not use `helm test`.

The lock contains PostgreSQL `12.1.15`, Redis `19.6.4`, ClickHouse `4.1.16`, Vector
`0.19.2`, Grafana `6.60.6`, and disabled Nuclio `0.22.10` and Traefik `37.3.0` charts.
These are chart versions, not image versions. The dependency and workload tables in
`docs/milestone-4a-offline-render.md` record the effective images, including parent-chart
overrides. Do not infer image versions from dependency `appVersion` alone.

### Resource guardrails and storage

`helm/cvat/values-m4a-poc.yaml` and the render test define steady-state requests of
`3050m` CPU / `5120Mi` memory and an initializer-inclusive total of `3150m` / `5376Mi`.
These are scheduler requests, not measured utilization or production sizing. Server and
each worker have a `4Gi` memory limit; initializer, PostgreSQL, and KVrocks have `2Gi`;
ClickHouse has `4Gi`; frontend, OPA, Redis, Vector, and Grafana have `512Mi`.
CPU limits are omitted for server, workers, initializer, PostgreSQL, KVrocks, and
ClickHouse. Frontend, OPA, Vector, and Grafana use `500m`; Redis retains `150m`.

The chart cannot set independent nginx sidecar resources. The approved server-pod
request is assigned to the backend container; nginx has no independent request/limit.
The permission-fix init container also lacks an exposed resource override. These are
accepted exact-chart limitations, documented in `docs/milestone-4a-offline-render.md`.

`kubernetes/platform/storage-classes.yaml` defines:

- `cvat-rwx`: Azure Files CSI, SMB, `Standard_LRS`, expansion enabled, immediate
  binding, `Retain`; mount options `dir_mode=0755`, `file_mode=0755`, `uid=1000`,
  `gid=1000`, `cache=strict`, and `nosharesock`.
- `cvat-rwo`: Azure Disk CSI, `StandardSSD_LRS`, expansion enabled,
  `WaitForFirstConsumer`, and `Retain`.

The released claims request 20 GiB RWX for shared backend data, and four separate RWO
claims: PostgreSQL 8 GiB, Redis 8 GiB, KVrocks 100 GiB, and ClickHouse 8 GiB. These are
requested PVC capacities, not a production capacity forecast or a statement of billed
Azure allocation. Vector and Grafana are ephemeral in this baseline. The backend PVC
also has `helm.sh/resource-policy: keep`.

## 4. Deployment and Validation Results

- **Platform recreation:** `docs/milestone-1.md` and `docs/milestone-3-plan.md` record
  successful platform validation and zero Terraform drift. The later recreation section
  of `docs/milestone-4a-offline-render.md` records recreation from zero state.
- **Application convergence:** that later recreation deployed CVAT successfully on the
  first Helm attempt with the Django remediation included. The initializer completed,
  all 20 long-running pods became Ready, and no Django hard-link failure recurred.
- **Basic persistence:** `docs/milestone-3-plan.md` records bidirectional cross-node RWX
  access, ownership `1000:1000`, mode `0755`, RWX persistence after pod recreation, and
  same-node RWO persistence/remount. Cross-node RWO detach/reattach was not tested.
- **Browser access:** `docs/local-cvat-access.md` and the M4 recreation evidence record
  correct frontend/API routing, backend JSON responses, and successful interactive login
  with a local POC account. No project/task or annotation workflow was completed.
- **Teardown:** the prior operational closeout reported successful full application,
  storage, and infrastructure removal with no remaining POC resources. During preparation
  of this handoff, a read-only local check confirmed zero managed Terraform instances.
  `docs/milestone-3-plan.md` records the earlier clean platform teardown; the application
  cleanup procedure is in `docs/milestone-4a-offline-render.md`. The committed documents
  do not retain a final Azure inventory for the last session. Zero local state alone is
  not independent proof of zero Azure resources; no fresh Azure audit was performed for
  this handoff.

## 5. Technical Findings

**Application topology.** The frontend serves the browser UI; the backend handles the
API; OPA supplies authorization decisions; Redis queues work for independently deployed
annotation, chunks, consensus, export, import, quality-report, utility, and webhook
workers. The initializer performs database initialization/migrations. PostgreSQL holds
application users, roles, tasks, jobs, and annotation metadata. KVrocks is a separate
on-disk Redis-compatible dependency. Analytics flows through Vector to ClickHouse and
Grafana. See `docs/cvat-application-discovery.md` and the released workload map in
`docs/milestone-4a-offline-render.md`.

**Filesystem semantics.** The backend claim carries uploaded/prepared media, task and
project data, caches, temporary working files, and separate keys/logs subpaths. Multiple
backend workloads share it. RWX access mode alone is insufficient to describe CVAT
storage compatibility; required filesystem semantics must be evaluated per application
path. Basic mount/write tests and healthy pods do not prove the media path works.

**Django signing-key failure and fix.** The initial live installation failed under
`/home/django/keys/secret_key.py`: CVAT attempted atomic key publication with `os.link()`,
and Azure Files SMB returned `Errno 95`. Backend/worker failures also prevented OPA from
loading its policy bundle. The recorded upstream guidance and source behavior show
that `DJANGO_SECRET_KEY` bypasses filesystem key loading/generation. Tracked values use
`cvat.backend.additionalEnv` with `valueFrom.secretKeyRef` to supply one stable key to
the initializer, server, and every worker type. No chart fork or storage change was
required. The PostgreSQL dependency's `extraDeploy` hook packages the dedicated Secret;
PostgreSQL does not logically own the key. Production materialization and rotation must
be reviewed independently. Sources: `helm/cvat/values-m4a-poc.yaml`,
`helm/cvat/values-m4b-secrets.example.yaml`, and the live-failure section of
`docs/milestone-4a-offline-render.md`.

**Same-origin routing.** Forwarding the frontend Service alone returns frontend HTML
for API requests, causing schema/authentication errors. `scripts/cvat-local-proxy.mjs`
combines frontend and backend forwards at a loopback origin. Its backend routes are
`/api`, `/admin`, `/static`, `/django-rq`, and `/profiler`; other paths reach the UI.
`docs/local-cvat-access.md` documents the commands and JSON checks. This is workstation
access tooling, not a production ingress design.

**Persistence and cleanup.** Helm uninstall alone does not remove the retained backend
claim, StatefulSet claims, or backing storage. The cleanup workflow captures exact
identities, checks live consumers, and narrowly enables CSI deletion. A discovered
StrictMode defect in non-PVC volume inspection was corrected in
`scripts/CvatCleanup.Common.psm1`; `scripts/tests/test-cvat-cleanup-offline.ps1` covers
PVC, mixed/non-PVC, and malformed-volume cases. Preserve these refusal checks.

**Resources and observability.** `docs/milestone-3-plan.md` measured each application
node at `3860m` CPU / `12075760Ki` memory allocatable, with DaemonSet requests of `310m`
CPU / `576Mi` per node. The system node had `1900m` / `5928364Ki`; each node allowed 250
pods. These are historical capacity/request observations, not throughput measurements.
Use pod/node metrics, requests/limits, events, restart/probe observations, queue behavior,
and storage measurements for subsequent experiments. No representative-load performance
baseline is established. The bundled analytics stack serves CVAT analytics and does not
establish production platform monitoring or operational ownership.

## 6. Known Limitations and Unvalidated Requirements

The deferred work recorded in `docs/milestone-3-plan.md`,
`docs/cvat-application-discovery.md`, and `docs/milestone-4a-offline-render.md` includes:

- Successful media ingestion, task creation, annotation, chunk generation, export, and
  task/media/cache/tmp filesystem behavior on Azure Files SMB.
- Representative concurrency, latency, throughput, CPU/memory use, storage performance,
  failure recovery during active work, and production dataset capacity/retention.
- Cloud-backed datasets, their authentication, source-copy behavior, and cache growth.
- Production HA, scaling, upgrades, disruption budgets, and resilience; two application
  nodes do not establish full-topology survival after losing one node.
- Cross-node Azure Disk detach/reattach and application-level backup/restore/disaster
  recovery. CSI snapshot-controller health does not prove recoverability.
- Analytics-enabled versus analytics-disabled resource and behavior comparison.
- Enterprise licensing and exact SSO/Okta behavior, group-to-role/organization mapping,
  and disabling local registration/password login. Local POC login proves none of these.
- GPU/Nuclio/agent inference integration, isolation, scheduling, and network boundaries.

## 7. Corporate Portability Considerations

The personal POC Terraform must not be applied directly to corporate Azure. Start with
an approved read-only assessment of the target platform. The following are decisions to
resolve, not claims that a particular corporate architecture is required:

- **Existing versus dedicated AKS:** assess application ownership, isolation, cluster
  policy, namespace/RBAC, and the chart's cluster-scoped Grafana RBAC before choosing.
- **Networking:** replace/review region and CIDR inputs in
  `infrastructure/aks/variables.tf`; check corporate routing, DNS, egress, private access,
  ingress and TLS policy. External-subnet support currently requires one subscription.
- **Identity and secrets:** review AKS local accounts, identity/RBAC and subnet assignment
  authority in `infrastructure/aks/main.tf`. Use approved corporate authentication and
  secret delivery. Workload Identity enablement is only a platform capability.
- **Storage:** validate filesystem compatibility, performance, encryption/access policy,
  retention, backup and recovery. Reuse corporate storage only after compatibility is
  established. Keep disposal tooling separate from production retention decisions.
- **Compute:** align labels, taints, quotas, node sizes, and upgrade headroom with corporate
  policy; use measurements rather than importing the POC sizing as a requirement.
- **State and delivery:** `infrastructure/aks/versions.tf` has no remote backend; the POC
  uses local state. Establish approved remote state, access controls, locking, pipeline
  identity, plan review, and artifact/image provenance before shared operation.
- **Operations:** identify owners for CVAT, databases, storage, security updates, alerts,
  backups, incidents and costs. Evaluate existing monitoring before adding another stack.

Do not transfer ignored secret overlays, Terraform state/backups/plans, kubeconfigs, or
runtime ledgers as part of the source handoff. `.gitignore` excludes these categories.
Git attribution and older documentation may contain personal information; review the
source/history separately before wider distribution. This document intentionally omits
personal and deployment-specific identifiers.

## 8. How to Reproduce the POC

Reproduction requires explicit approval and fresh environment verification. Use
`README.md` for platform setup, `docs/milestone-4a-offline-render.md` for chart/values,
secret, deployment gates and application cleanup, and `docs/local-cvat-access.md` for
browser access. Do not treat the README's Terraform-only teardown example as sufficient
after application storage has been created.

Prerequisites are Terraform >= 1.6 with the committed AzureRM lock (currently 4.81.0;
constraint >= 4 and < 5), Azure CLI, kubectl, PowerShell 7, Helm (recorded offline render
used 4.2.3), Node.js for the local proxy, and Python with PyYAML for render assertions.
The operator needs approved Azure/Kubernetes permissions, required resource providers,
available node SKUs/quota, registry access, and tools compatible with the recorded
workflow. Sources: `infrastructure/aks/versions.tf`,
`infrastructure/aks/.terraform.lock.hcl`, `README.md`, and the scripts listed above.

1. Verify Git status, intended Azure authentication/context, and Terraform workspace/state.
   Create ignored `infrastructure/aks/terraform.tfvars` from its example using newly
   approved inputs. Run Terraform init, format check, validate, and test; review a saved
   plan before applying. In standalone mode expect the seven resources described above.
2. Obtain AKS credentials through the Terraform output and validate nodes, placement
   controls, Cilium, identity settings, CSI components and kube-system health. Confirm
   zero drift. Apply `kubernetes/platform/storage-classes.yaml` separately.
3. If repeating the basic storage experiment, follow
   `kubernetes/validation/storage/README.md`, run `scripts/validate-storage.ps1`, and
   immediately complete `scripts/cleanup-storage-validation.ps1`. Retain makes cleanup
   mandatory; these test scripts must not be used for CVAT application claims.
4. Pull chart 2.76.0 from the approved OCI reference, verify both recorded OCI digest and
   archive hash, and use its packaged dependencies. Only chart `values.yaml` loads
   automatically; do not add upstream `cvat.values.yaml` implicitly. Preserve access to
   the verified archive for cleanup's maintenance overlay.
5. Run `scripts/New-CvatM4bSecrets.ps1` to create the ignored
   `helm/cvat/values-m4b-secrets.local.yaml`. It refuses overwrite and generates eight
   unique values with 256 bits of randomness each: three PostgreSQL credentials, Redis,
   KVrocks, ClickHouse, Grafana, and the Django key. Validate ignore rules/schema without
   displaying values. Helm stores supplied values in release data; this POC mechanism
   is not the production secret architecture.
6. Lint and render with `helm/cvat/values-m4a-poc.yaml` followed by the local overlay.
   Validate through `scripts/tests/test-cvat-render.py` using a protected temporary
   output directory and remove the render afterward. The current assertions expect
   59 documents including six Secrets and the unused test-hook Pod, unchanged workload
   counts, five eventual claims, pinned CVAT images, Django references, scheduling,
   requests, and no Ingress/Traefik/Nuclio. Never print rendered secrets.
7. Before installation run `scripts/capture-cvat-storage-baseline.ps1` with the approved
   cluster scope. It records a fresh ignored baseline. Never reuse deleted storage
   identities from an earlier deployment. Install the verified archive using the same
   ordered values files; observe the initializer and all long-running workloads.
8. Verify five bound PVC/PV pairs, Django Secret references, no hard-link errors or
   recurring crash loops, and zero Terraform drift. Run
   `scripts/inventory-cvat-storage.ps1` to capture the fresh cleanup ledger. Stop on
   identity mismatches or unexpected resources. Run no automatic fix-forward changes.
9. Follow `docs/local-cvat-access.md`: frontend forward on loopback port 18000, backend
   forward on 18080, proxy on 8081. Confirm UI and backend schema/health/about JSON.
   If approved, create a local application account using the backend's supported Django
   management command with an interactive password prompt; do not store that password.
10. Stop local access and, after explicit data-disposal approval, revalidate the ledger
    with `scripts/cleanup-cvat.ps1 -InventoryOnly -ChartArchivePath <verified-archive>`.
    Follow the documented destructive confirmation procedure. The script quiesces CVAT,
    uninstalls Helm, refuses live PVC consumers, changes only captured PVs from Retain
    to Delete, deletes exact claims, and waits for CSI removal without forcing finalizers.
    Verify four disks and the file share are absent; delete the captured storage account
    only when the script's baseline/scope/emptiness guards permit it. Verify namespace
    cleanup and preserve platform resources until application cleanup succeeds.
11. Only then review the Terraform destroy plan and remove its approved scope. Verify
    empty managed state and absence of POC resources in both resource groups. Remove
    consumed local ledgers after successful cleanup; preserve source and documentation.

Offline validation entry points are `terraform fmt -check -recursive`,
`terraform validate`, and `terraform test` from `infrastructure/aks`, plus
`scripts/tests/test-cvat-secret-generation.ps1`,
`scripts/tests/test-cvat-cleanup-offline.ps1`,
`node --test scripts/tests/test-cvat-local-proxy.mjs`, and
`python scripts/tests/test-cvat-render.py <temporary-render-directory>`.

## 9. Recommended Next Steps

1. Confirm that the CVAT initiative is still active and identify application owners,
   intended users, workflows, security constraints, and operational responsibilities.
2. Perform an approved read-only architecture assessment against existing corporate
   capabilities before deciding whether to reuse or create platform resources.
3. In an approved test environment, create a task with representative sample media,
   process it, annotate it, and export results. Exercise chunk/cache/tmp behavior and
   capture errors and resource/storage measurements before production sizing.
4. Establish dataset capacity, retention, concurrency, recovery, and access requirements;
   then test cloud-backed datasets and the analytics-disabled comparison if relevant.
5. Investigate Enterprise licensing/SSO only with confirmed identity requirements.
6. If inference is needed, compare Nuclio and agent integration and determine whether
   GPU workloads belong on separate nodes or a separate cluster. Neither placement is
   selected or proven by this POC; preserve the application/inference boundary during
   that assessment. See `docs/cvat-application-discovery.md` for the discovery inputs.

## 10. Explicit Instructions for the Receiving Assistant

- Treat this repository as a validated POC with the limits above, not production-ready
  infrastructure or authorization to operate a corporate subscription.
- Do not assume the original personal Azure environment exists or copy its local state,
  credentials, context, or cleanup identities into another environment.
- Do not deploy, modify infrastructure, or rewrite the architecture without approval.
  Begin with repository evidence and an approved read-only target-environment assessment.
- Distinguish recorded validation, chart/configuration facts, assumptions, and future
  recommendations. Preserve the distinction between healthy startup/login and successful
  media/annotation workflows, and between basic RWX tests and filesystem compatibility.
- Prefer existing corporate platform capabilities when compatible with verified CVAT
  requirements. Do not infer that every component used in this POC must be duplicated.
- Preserve cleanup refusal checks, require fresh ledgers, and stop on ambiguous identities.
  Never widen deletion scope to make teardown pass.
- Keep credentials out of conversation output, tracked files, and retained renders.
  Review proposed changes and their evidence before requesting deployment approval.
