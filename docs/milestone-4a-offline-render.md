# Milestone 4a: CVAT 2.76.0 offline Helm render

Milestone 4a establishes exactly what the approved released CVAT chart renders before
Azure is recreated. Nothing in this milestone was installed into Kubernetes.

## Approved and verified baseline

| Item | Approved value |
| --- | --- |
| CVAT release | `v2.76.0` |
| Release commit | `b78c39f7a5de6450567e77c9e1ffc8f0c428cea7` |
| Helm chart | `2.76.0` |
| Official reference | `oci://registry-1.docker.io/cvat/cvat` |
| OCI artifact digest | `sha256:9ce13e269106129e6f26b8e60059009a215c861a7d96bde47602ace19e71c105` |
| Pulled chart archive SHA-256 | `fe22aa4aa47cadd25991915da8f120361131afb98f8bd005d18d13b71836f2da` |
| Backend image | `cvat/server:v2.76.0` |
| Frontend image | `cvat/ui:v2.76.0` |

The OCI digest was verified when Helm pulled the artifact. The release chart's
`appVersion` is `latest`, but the effective image tags in its `values.yaml` are explicitly
`v2.76.0`; `appVersion` is not used to choose the images.

The M2 research commit, `f87f4a32dd13f031288e69c64304ac80d49284fd`, remains valid
historical application-discovery input. It is not the M4 deployment baseline: it is a
post-release development commit whose source chart is `2.76.1`, whose CVAT images default
to `dev`, and for which no official `2.76.1` OCI artifact was found.

Primary upstream references are the [CVAT v2.76.0 release](https://github.com/cvat-ai/cvat/releases/tag/v2.76.0),
the tagged [Chart.yaml](https://github.com/cvat-ai/cvat/blob/v2.76.0/helm-chart/Chart.yaml),
[values.yaml](https://github.com/cvat-ai/cvat/blob/v2.76.0/helm-chart/values.yaml),
and the official [Helm deployment guide](https://github.com/cvat-ai/cvat/blob/v2.76.0/site/content/en/docs/administration/community/advanced/k8s_deployment_with_helm.md).

## Dependency lock

The approved OCI artifact contains `Chart.lock` and vendored dependencies. No dependency
update is required or permitted for this baseline.

| Dependency chart | Locked version | Packaged appVersion | Plain-default state |
| --- | ---: | ---: | --- |
| PostgreSQL | `12.1.15` | `15.2.0` | Enabled |
| Nuclio | `0.22.10` | `1.16.10` | Disabled |
| Vector | `0.19.2` | `0.27.1-distroless-libc` | Enabled by analytics |
| ClickHouse | `4.1.16` | `23.12.2` | Enabled |
| Grafana | `6.60.6` | `10.1.5` | Enabled by analytics |
| Traefik | `37.3.0` | `v3.6.0` | Disabled |
| Redis | `19.6.4` | `7.2.5` | Enabled |

The lock digest is
`sha256:211e0df102f5b1087de865216ba8b18c2ee5d74f61f719cdee0c1a50e45a79d6`.
Parent values override some dependency images, so rendered images—not dependency
`appVersion` fields—are authoritative. In particular, Redis renders `7.2.11` and Vector
renders `0.26.0-alpine`.

## Values-loading strategy

Helm automatically loads only the chart's `values.yaml`. Packaged sibling files are not
implicitly merged:

- `cvat.values.yaml` enables analytics, Ingress, and Traefik. Analytics is already enabled
  in `values.yaml`; Ingress and Traefik are not.
- `values-maintenance.yaml` scales CVAT application Deployments to zero and disables the
  initializer.
- `test.values.yaml` is an upstream test profile that disables most workers and changes
  storage and image-pull behavior.

The plain-default baseline therefore uses only `values.yaml`. It enables bundled analytics,
PostgreSQL, Redis, KVrocks, ClickHouse, Vector, and Grafana. It renders no Ingress,
Traefik workload, or Nuclio workload. This resolves the M2 ambiguity: the official guide's
statement that Traefik ingress is enabled by default is not true for a plain Helm render of
the approved artifact. Loading `cvat.values.yaml` would be an explicit operator choice.

The M4b-ready `helm/cvat/values-m4a-poc.yaml` supplies the values required to integrate
with proven M3 capabilities:

- required placement on nodes labeled `workload=cvat`;
- toleration of `workload=cvat:NoSchedule`;
- `cvat-rwx` for the shared backend claim; and
- `cvat-rwo` for the four stateful dependency claims; and
- approved POC scheduling requests and memory safety limits.

It deliberately does not configure credentials, ingress, application behavior, analytics
changes, replicas, or image versions. Effective CVAT image tags are already pinned by the
approved chart and are recorded above.

## Approved initial M4b decisions

- Use `kubectl port-forward` for the first UI/API access. Do not enable Ingress or
  Traefik; ingress architecture remains deferred.
- Use chart `2.76.0`, the verified OCI digest, `cvat/server:v2.76.0`,
  `cvat/ui:v2.76.0`, and the packaged dependency lock. Container image digests are not
  required for this POC. Digest enforcement remains a stronger production or supply-chain
  reproducibility control.
- Do not run `helm test` in the initial validation. The Grafana test-hook Pod therefore
  does not need CVAT-pool scheduling overrides.
- Keep Azure Files permission-fix behavior enabled and make it an explicit live validation
  criterion rather than assuming an offline incompatibility.

## Plain-default rendered inventory

Helm `4.2.3` rendered 58 Kubernetes documents.

| Kind | Count |
| --- | ---: |
| Deployment | 12 |
| StatefulSet | 5 |
| Job | 1 |
| Pod | 1 Helm test hook |
| Service | 13 |
| PersistentVolumeClaim | 1, plus four StatefulSet claim templates |
| ConfigMap | 9 |
| Secret | 5 |
| ServiceAccount | 5 |
| Role / RoleBinding | 1 / 1 |
| ClusterRole / ClusterRoleBinding | 1 / 1 |
| NetworkPolicy | 1 |
| PodDisruptionBudget | 1 |
| Ingress | 0 |
| DaemonSet | 0 |

All 13 Services are `ClusterIP`. The RBAC objects belong to Grafana. The Redis dependency
creates the NetworkPolicy and PodDisruptionBudget. The separate Grafana test Pod is marked
with the `test-success` Helm hook and is not a long-running workload.

## Workload and purpose map

| Workload | Form / replicas | Containers | Purpose |
| --- | --- | --- | --- |
| `cvat-frontend` | Deployment / 1 | `cvat/ui:v2.76.0` | Browser UI |
| `cvat-backend-server` | Deployment / 1 | two `cvat/server:v2.76.0` containers | Django API/application server plus nginx proxy |
| annotation worker | Deployment / 1 | `cvat/server:v2.76.0` | Automatic-annotation queue orchestration |
| chunks worker | Deployment / 2 | `cvat/server:v2.76.0` | Media chunk generation and delivery |
| consensus worker | Deployment / 1 | `cvat/server:v2.76.0` | Consensus operations |
| export worker | Deployment / 2 | `cvat/server:v2.76.0` | Dataset and annotation export |
| import worker | Deployment / 2 | `cvat/server:v2.76.0` | Imports and task/data creation |
| quality-reports worker | Deployment / 1 | `cvat/server:v2.76.0` | Quality report processing |
| utils worker | Deployment / 1 | `cvat/server:v2.76.0` | Notifications, cleanup, and scheduled utilities |
| webhooks worker | Deployment / 1 | `cvat/server:v2.76.0` | Webhook delivery |
| `cvat-opa` | Deployment / 1 | `openpolicyagent/opa:1.12.2` | Authorization policy decisions |
| `cvat-grafana` | Deployment / 1 | `grafana/grafana:10.1.5` | Analytics dashboards |
| `cvat-postgresql` | StatefulSet / 1 | PostgreSQL `15.2.0-debian-11-r0` | Authoritative CVAT relational metadata |
| `cvat-redis-master` | StatefulSet / 1 | Redis `7.2.11` | RQ queues and in-memory cache |
| `cvat-kvrocks` | StatefulSet / 1 | `apache/kvrocks:2.15.0` | Redis-compatible on-disk application/operational state |
| `cvat-clickhouse-shard0` | StatefulSet / 1 | ClickHouse `23.12.2-debian-11-r0` | Analytics and event storage |
| `cvat-vector` | StatefulSet / 1 | `timberio/vector:0.26.0-alpine` | Event forwarding into ClickHouse |
| backend initializer | Job / 1 completion | `cvat/server:v2.76.0` | Database initialization and migrations |

The eight worker types have 11 running replicas in total and one process per replica. The
plain baseline has 20 long-running pods and 21 long-running containers. The permission-fix
init container uses `busybox:1.36.1` on backend pods that mount shared data.

## Scheduling analysis

Plain defaults contain no CVAT-pool tolerations and no required `workload=cvat` placement.
They cannot schedule on the proven M3 cluster: the system node rejects normal application
pods through `CriticalAddonsOnly`, while the CVAT nodes reject pods that do not tolerate
`workload=cvat:NoSchedule`.

The chart supports clean overrides without a fork:

- shared `cvat.backend.affinity` and `cvat.backend.tolerations` cover the server,
  initializer, and every worker;
- frontend, OPA, and KVrocks expose component affinity/tolerations; and
- PostgreSQL, Redis, ClickHouse, Vector, and Grafana expose dependency-specific
  node-selector/toleration values.

The proposed POC render was checked programmatically. All 12 Deployments, five
StatefulSets, and the initializer Job require `workload=cvat` and tolerate the taint. The
Grafana Helm test hook is not part of normal installation and is not yet scheduled by the
POC values. No topology-spread rule is added: two nodes permit cross-node behavior, but HA
and guaranteed spreading remain out of scope.

## Storage and state map

| Claim / path | Consumers and purpose | Plain default | Proposed M3 mapping | Requirement |
| --- | --- | --- | --- | --- |
| `cvat-backend-data` | Server, annotation, chunks, export, import, and utils; `/home/django/data`, keys, logs, media, caches, imports/exports | 20 GiB, RWX, no class, `helm.sh/resource-policy: keep` | `cvat-rwx` | Mandatory while default storage is enabled; RWX is required for current cross-node multi-pod topology |
| PostgreSQL `data` | Authoritative users/projects/tasks/jobs/annotations metadata | 8 GiB, RWO, no class | `cvat-rwo` | Mandatory for bundled PostgreSQL; RWO sufficient for one replica |
| Redis `redis-data` | Queues and cache | 8 GiB, RWO, no class | `cvat-rwo` | Enabled and persistent by default; external/disabled Redis is supported but not selected |
| KVrocks `cvat-kvrocks-data` | On-disk Redis-compatible state | 100 GiB, RWO, no class | `cvat-rwo` | Mandatory while bundled KVrocks is enabled; RWO sufficient for one replica |
| ClickHouse `data` | Analytics/events | 8 GiB, RWO, no class | `cvat-rwo` | Mandatory while bundled analytics/ClickHouse is enabled; RWO sufficient for one replica |
| Vector data directory | Forwarding/buffering | No PVC | Ephemeral | Persistence is optional and disabled in the baseline |
| Grafana data | Dashboard runtime | No PVC | Ephemeral | Persistence is optional and disabled in the baseline |

The proposed render contains exactly these five persistent claims with the expected
classes, access modes, and sizes. M3 proved cross-node Azure Files RWX semantics and
same-node Azure Disk RWO persistence/remount. It did not prove Azure Files throughput for
CVAT or cross-node Azure Disk detach/reattach.

Both M3 StorageClasses use `Retain`, and the backend claim also carries Helm's keep policy.
M4b therefore needs an explicit application-storage cleanup ledger and procedure before
any live installation. The M3 validation cleanup script is intentionally scoped to its
test claims and must not be reused as unscoped CVAT cleanup.

## Resource requests and limits

The effective plain-default long-running requests are only `350m` CPU and `384Mi` memory
for the whole application:

- PostgreSQL requests `250m` CPU and `256Mi` memory and has no CPU/memory limits.
- Redis requests `100m` CPU, `128Mi` memory, and `50Mi` ephemeral storage; it limits CPU
  to `150m`, memory to `192Mi`, and ephemeral storage to `2Gi`.
- ClickHouse renders explicit empty request/limit maps.
- Every CVAT container, permission-fix init container, frontend, OPA, KVrocks, Vector, and
  Grafana container has no CPU or memory request or limit.

This is not a useful measurement baseline: Kubernetes could pack nearly all pods on one
node and would have little information for admission or rescheduling decisions.

The following are implemented M4b guardrails, not upstream requirements or production sizing.
CPU limits are intentionally omitted except where the released Redis chart already has
one: CPU-heavy media behavior should be observable rather than capped at an arbitrary
rate. Memory limits provide a high safety boundary and must be reviewed after measurement.

| Workload / container | Role | Replicas | Upstream request CPU / memory | Proposed request CPU / memory, per container | Proposed limit CPU / memory | Rationale |
| --- | --- | ---: | --- | --- | --- | --- |
| Backend server pod | API and proxy | 1 pod, 2 containers | none / none | `cvat-backend`: `400m` / `768Mi`; `cvat-nginx`: unset | backend: none / `4Gi`; nginx: unset | The released template exposes resources only for the backend container. Assigning the approved pod aggregate to it keeps the pod scheduler-visible without forking the chart. |
| Frontend | UI | 1 | none / none | `50m` / `64Mi` | `500m` / `512Mi` | Lightweight but scheduler-visible |
| Annotation worker | Automatic-annotation orchestration | 1 | none / none | `150m` / `256Mi` | none / `4Gi` | Establishes placement while allowing data-dependent work |
| Chunks worker | Media decoding/encoding | 2 | none / none | `150m` / `256Mi` | none / `4Gi` | CPU-heavy measurement target; no CPU cap |
| Consensus worker | Consensus processing | 1 | none / none | `150m` / `256Mi` | none / `4Gi` | Conservative admission request |
| Export worker | Archive/conversion/export | 2 | none / none | `150m` / `256Mi` | none / `4Gi` | CPU/memory measurement target; no CPU cap |
| Import worker | Import/task creation/media preparation | 2 | none / none | `150m` / `256Mi` | none / `4Gi` | CPU/memory measurement target; no CPU cap |
| Quality-reports worker | Quality computation | 1 | none / none | `150m` / `256Mi` | none / `4Gi` | Data-dependent workload |
| Utils worker | Notifications and cleanup | 1 | none / none | `150m` / `256Mi` | none / `4Gi` | Makes background work scheduler-visible |
| Webhooks worker | Webhook delivery | 1 | none / none | `150m` / `256Mi` | none / `4Gi` | Conservative common worker baseline |
| OPA | Authorization | 1 | none / none | `50m` / `64Mi` | `500m` / `512Mi` | Small steady service with bounded memory |
| PostgreSQL | Relational system of record | 1 | `250m` / `256Mi` | `250m` / `256Mi` | none / `2Gi` | Retains upstream request; avoids imposing an arbitrary CPU cap |
| Redis | Queue and cache | 1 | `100m` / `128Mi` | `100m` / `128Mi` | upstream `150m` / proposed `512Mi` | Retains upstream request and CPU limit for the first baseline; raises only the low memory ceiling for observation |
| KVrocks | On-disk Redis-compatible state | 1 | none / none | `100m` / `256Mi` | none / `2Gi` | Adds admission signal without CPU throttling |
| ClickHouse | Analytics store | 1 | empty / empty | `250m` / `512Mi` | none / `4Gi` | Analytics is enabled and must be represented in scheduling |
| Vector | Event forwarder | 1 | none / none | `100m` / `128Mi` | `500m` / `512Mi` | Small steady pipeline component |
| Grafana | Analytics UI | 1 | none / none | `100m` / `128Mi` | `500m` / `512Mi` | Small steady UI component |
| Initializer Job | Migrations/bootstrap | 1 transient | none / none | `100m` / `256Mi` | none / `2Gi` | Ensures bootstrap can schedule; excluded from steady-state totals |

At released replica counts the implemented running requests total exactly `3050m`
CPU and `5120Mi` memory. M3 measured aggregate post-DaemonSet capacity across two CVAT
nodes at approximately `7100m` CPU and `22434Mi` memory, leaving about `4050m` CPU and
`17314Mi` memory for bursts and measurement. Placement still needs an offline scheduling
feasibility check after these values are approved and rendered. No resources are proposed
for the permission-fix init container because the chart exposes no clean value for them.

While the initializer runs, requests temporarily rise to `3150m` CPU and
`5376Mi` memory. Requests are aggregate values; required node placement is proven, but
balanced distribution is not guaranteed because HA/spread constraints remain deferred.

The nginx sidecar is the only long-running container without its own request or limit.
This is an exact-chart limitation, not an omitted value: chart `2.76.0` provides no nginx
resource key. The server pod still requests the approved aggregate through its backend
container. A later production baseline should prefer an upstream chart capability or a
reviewed post-render policy if per-container nginx boundaries are required.

## Authentication and production identity discovery

M4b Community POC access will use local CVAT authentication only to validate application
functionality. This is not the proposed production identity architecture. CVAT persists
application users and their application-level roles in its PostgreSQL-backed application
data.

A production candidate may use CVAT Enterprise with organizational Okta SSO. Okta would
remain the authentication authority while CVAT retains application-level user and role
records. Production discovery must investigate Okta-group mapping to CVAT roles and
organizations, and validate whether local registration and password login can be disabled
under Enterprise SSO. Enterprise licensing and the exact supported SSO behavior remain
production discovery items. M4b adds no Okta/OIDC secrets or Enterprise-only settings.

## Offline M4b cleanup tooling

Cleanup is implemented as a deliberately staged workflow:

1. Before Helm installation, `scripts/capture-cvat-storage-baseline.ps1` records the exact
   subscription, cluster, node resource group, namespace/release intent, and pre-existing
   storage accounts in ignored `artifacts/cvat-storage-baseline.json`.
2. After all five claims bind, `scripts/inventory-cvat-storage.ps1` captures the exact PVC,
   PV, claimRef, CSI driver, volume handle, and Azure Files identity in ignored
   `artifacts/cvat-cleanup-ledger.json`. It refuses missing, extra, or ambiguous claims.
3. `scripts/cleanup-cvat.ps1 -InventoryOnly` revalidates the ledger without mutation.
   Destructive mode additionally requires the approved chart archive SHA-256, PowerShell
   confirmation, and the exact typed phrase printed by the script.
4. Destructive mode uses the packaged maintenance values to quiesce CVAT, uninstalls Helm,
   proves no pod consumes a captured claim, changes only the five captured PVs from
   `Retain` to `Delete`, and deletes the five exact PVC names. This accounts for both the
   backend keep annotation and StatefulSet-created claims.
5. It waits for CSI deletion, verifies four managed-disk IDs and the Azure Files share are
   absent, and removes a CSI-created storage account only when the predeployment ledger
   proves it is new, it is in the AKS node resource group, and management-plane enumeration
   proves that it has no shares. It then removes only the empty CVAT namespace and proves
   both platform StorageClasses still exist.

The tooling never selects deletion targets by label and never deletes a resource group.
Any mismatch stops cleanup without broadening scope. Offline tests accept one valid ledger
and reject missing claims, driver/class/claimRef mismatches, duplicate CSI identities, and
unsafe namespaces. Live behavior remains subject to validation during M4b.

## Bundled dependency boundaries

| Component | Classification | Baseline | Persistence and coupling | Supported boundary |
| --- | --- | --- | --- | --- |
| PostgreSQL | Core application dependency | Enabled | RWO; authoritative metadata; tightly coupled to all backend paths | Chart supports disabling it and supplying an external host |
| Redis | Core application dependency | Enabled | RWO; RQ queues/cache; all workers depend on it | Chart supports disabling it and supplying an external host |
| KVrocks | Core application dependency | Enabled | RWO; configured as CVAT's on-disk Redis endpoint | Enabled/external-host boundary exists |
| ClickHouse | Analytics dependency | Enabled | RWO; receives events through Vector | Can be disabled or external when analytics settings are adjusted |
| Vector | Analytics dependency | Enabled | Ephemeral; forwards events to ClickHouse | Removed when analytics is disabled |
| Grafana | Analytics dependency | Enabled | Ephemeral; reads ClickHouse dashboards | Removed when analytics is disabled |
| Traefik | Ingress/access dependency | Disabled | No CVAT state | Can be explicitly enabled; not intrinsic to CVAT |
| Nuclio | Optional inference capability | Disabled | Would introduce controllers/functions and registry needs | Can be explicitly enabled; excluded from M4 baseline |

No bundled component is removed or replaced in the first M4 baseline. The later
analytics-disabled comparison remains a measurement experiment, not a baseline change.

## Minimal local secret delivery

Use an ignored Helm values file at
`helm/cvat/values-m4b-secrets.local.yaml`. Copy the committed
`values-m4b-secrets.example.yaml`, replace every placeholder with independently generated
random values, keep filesystem access limited to the operator, and pass the local file to
Helm after the non-secret POC values file. Passing it last ensures only the intended secret
fields are overridden:

```powershell
helm template cvat oci://registry-1.docker.io/cvat/cvat `
  --version 2.76.0 `
  --namespace cvat `
  -f helm/cvat/values-m4a-poc.yaml `
  -f helm/cvat/values-m4b-secrets.local.yaml
```

The `.local.yaml` path is ignored by Git. Before any live use, verify `git check-ignore`
and scan the staged diff. Helm will store supplied values in its in-cluster release Secret;
that is accepted for this short-lived POC and is not the production secret architecture.

### Secret inventory

| Secret material | Source for M4b | Rendered object/key | Required by |
| --- | --- | --- | --- |
| CVAT database password | Locally generated and supplied | `cvat-postgres-secret/password` | CVAT backend and PostgreSQL |
| PostgreSQL administrator password | Locally generated and supplied | `cvat-postgres-secret/postgres-password` | Bundled PostgreSQL administration |
| PostgreSQL replication password | Locally generated and supplied even though replicas are not enabled | `cvat-postgres-secret/replication-password` | PostgreSQL chart contract |
| Redis password | Locally generated and supplied | `cvat-redis-secret/password` | Redis and all backend queues/cache clients |
| KVrocks password | Locally generated and supplied | `cvat-kvrocks-secret/password` | KVrocks and backend on-disk Redis clients |
| ClickHouse password | Locally generated and supplied | `cvat-analytics-secret/CLICKHOUSE_PASSWORD` | ClickHouse, Vector/Grafana/backend analytics |
| Grafana administrator password | Locally generated and supplied to replace chart randomness | `cvat-grafana/admin-password` | Grafana bootstrap, although anonymous access is configured |

The chart also places non-secret connection metadata in those Secrets: PostgreSQL
`database`/`username`, ClickHouse database/user/host/port, and Grafana `admin-user`. Their
released values can remain unchanged for the POC. Grafana creates its Secret and would
generate a random password if none were supplied; supplying it locally makes the release
repeatable. PostgreSQL, Redis, KVrocks, and analytics Secret objects are chart-generated
from the local values above.

CVAT's Django key is application-generated and persisted under the shared backend volume;
it is not a separately rendered Kubernetes Secret. The initial CVAT user password is also
not a Helm value and must be entered interactively when the user is created. Neither value
belongs in Git or the local Helm values file.

## External dependencies

### Required to run the POC

- Kubernetes DNS and service networking for 13 internal ClusterIP Services.
- Outbound registry access to Docker Hub and public ECR for the rendered images.
- Dynamic provisioning through installed `cvat-rwx` and `cvat-rwo` StorageClasses.
- Secure values or pre-created Secrets for PostgreSQL, Redis, KVrocks, ClickHouse
  analytics, and Grafana. Released sample passwords are not acceptable deployment
  credentials. CVAT key material is persisted through the backend data volume rather than
  a separately rendered Kubernetes Secret and must be verified during M4b.
- Initial access uses approved `kubectl port-forward`; plain defaults expose no
  LoadBalancer or Ingress.

### Optional or production concerns

- DNS, public ingress, and TLS are not required when using port-forwarding.
- Cloud/object storage and its credentials are required only for later cloud-backed
  dataset tests.
- AKS Workload Identity is enabled at platform level but the chart does not create a
  federated identity or configure cloud-storage authentication.
- External databases, private endpoints, enterprise egress, and centralized secret
  management are production architecture choices, not M4a requirements.

## Retained-storage cleanup design

Cleanup is deliberately ledger-driven and two-phase. It must refuse unscoped deletion and
must require an explicit operator confirmation that all POC data is disposable.

1. **Capture a pre-deployment baseline.** Record the active subscription, AKS cluster,
   namespace, Helm release, node resource group, and pre-existing node-resource-group
   storage accounts in ignored local state. This allows a later distinction between reused
   and CSI-created storage accounts.
2. **Discover after binding.** Inventory the five expected PVCs and their PVs, claim refs,
   StorageClasses, access modes, capacities, CSI drivers, and volume handles. Resolve Azure
   Disk resource IDs and Azure Files account/share identities into an ignored cleanup
   ledger. Refuse unexpected claims, drivers, namespaces, or additional file shares.
3. **Confirm scope and disposability.** Recheck Azure subscription, kubectl context,
   cluster, namespace, release, and every live PV-to-PVC relationship against the ledger.
   Require an explicit destructive confirmation. Offer an inventory-only mode by default.
4. **Quiesce writes.** Stop new user activity and apply the packaged maintenance values to
   scale CVAT application Deployments to zero and disable the initializer. Wait for workers
   and Jobs to finish/terminate, then record final PVC usage. Bundled stateful dependencies
   remain available during this quiesce step.
5. **Uninstall Helm.** Run Helm uninstall only after the inventory and quiesce checks.
   This removes controllers, Services, RBAC, ConfigMaps, and Secrets. It does not remove
   the backend PVC because of `helm.sh/resource-policy: keep`; StatefulSet claim PVCs also
   remain, and all backing PVs still have the StorageClasses' `Retain` policy.
6. **Verify no consumers.** Confirm no pod or controller mounts any captured claim. Ensure
   only the five ledgered PVC/PV pairs remain in cleanup scope.
7. **Arm CSI deletion narrowly.** For each exact ledgered PV, verify its claim ref, CSI
   driver, volume handle, and class again, then change only that PV's reclaim policy from
   `Retain` to `Delete`. Do not change either platform StorageClass.
8. **Delete exact PVCs.** Delete the backend claim and the four StatefulSet claims by exact
   namespace/name. Wait for each PV to disappear; do not force-remove PV finalizers while
   CSI deletion is still progressing.
9. **Verify Azure backing cleanup.** Confirm every captured managed-disk resource ID and
   Azure Files share is absent. Delete a file storage account only if it was absent from the
   pre-deployment baseline, matches the captured CSI account, is in the expected node
   resource group, and contains no remaining shares. Otherwise retain the account and
   report it for review.
10. **Remove the namespace.** After storage deletion is proven, delete the empty CVAT
    namespace and remove the local cleanup ledger.
11. **Gate Terraform destroy.** Require zero CVAT pods, PVCs, PV claim refs, namespace,
    Helm release, managed disks, file shares, and unexpected storage accounts. Confirm the
    platform StorageClasses and AKS remain healthy and Terraform reports no drift before a
    separately reviewed `terraform plan -destroy`.

No cleanup action should use label-only or resource-group-wide deletion. Failure at any
verification step stops cleanup for manual review rather than broadening scope.

## Differences from M2 discovery

M2's component, replica, storage, service, probe, and GPU boundaries are substantially
confirmed. M4a adds or corrects these points:

1. The deployment baseline is released chart `2.76.0`, not development commit
   `f87f4a32` / chart `2.76.1`.
2. The released images are `cvat/server:v2.76.0` and `cvat/ui:v2.76.0`; `appVersion:
   latest` does not select them.
3. Plain defaults produce 12 Deployments, five StatefulSets, one initializer Job, and 20
   long-running pods. M2's 11-Deployment count referred to core CVAT Deployments and did
   not include Grafana.
4. Plain defaults render no Ingress or Traefik workload. `cvat.values.yaml` is an explicit
   overlay, not an automatic default.
5. Only PostgreSQL and Redis have nonzero resource requests; total scheduler-visible
   requests are `350m` CPU and `384Mi`, even lower than a topology-only review suggests.
6. The released OCI artifact supplies an exact dependency lock even though the tagged
   GitHub source tree does not retain `Chart.lock`.
7. The Grafana dependency creates cluster-scoped RBAC and a Helm test hook Pod.

## Proposed M4b success criteria

Before considering a live deployment successful:

1. Verify the chart digest, image tags, dependency lock, effective values, and namespace.
2. Confirm all intended controllers and the initializer schedule only on CVAT nodes and
   tolerate the CVAT taint; confirm no application pod uses the system pool.
3. Confirm all five claims bind to their intended StorageClasses, sizes, and access modes.
4. Confirm the initializer completes and all 20 intended long-running pods become Ready
   without recurring restarts.
5. Reach the UI and API using `kubectl port-forward` and create the initial CVAT user.
6. Create a project and task, upload representative image/video media, and verify shared
   media is accessible from the server and relevant workers.
7. Complete a basic annotation workflow, exercise chunk generation, and export results.
8. Recreate selected stateless pods and confirm application metadata, media, queues needed
   for active work, and analytics state remain usable.
9. Capture per-container CPU/memory working sets, throttling/OOM behavior, pod placement,
   queue behavior, PVC utilization, and storage latency during import/chunk/export.
10. Capture warnings, events, probe failures, image pulls, mount/permission behavior, and
    unexpected external calls or dependencies.
11. Repeat the measured baseline later with analytics disabled and record the topology,
    request, storage, and behavior delta.
12. Execute the approved application cleanup procedure and prove no retained POC disks,
    shares, claims, or secrets remain before destroying AKS.

## Remaining gates before live M4b deployment

Nothing in this review blocks recreation of the already-proven M3 platform. Before a
Helm installation creates CVAT workloads or persistent claims, complete these gates:

1. **Local credentials at execution time:** generate the ignored local values file, verify
   every placeholder is gone, and render without displaying or committing its contents.
2. **Pre-install storage baseline:** run the baseline capture after M3 recreation and before
   installing the Helm release; losing this baseline prevents automatic storage-account
   removal during cleanup.
3. **Server sidecar review:** accept the released chart's lack of a separate nginx resource
   value for this Community POC, or require a reviewed post-render mechanism before install.
4. **Azure Files permissions:** this is intentionally a live M4b criterion. Verify that the
   chart's permission-fix init containers complete on the validated UID/GID `1000:1000`,
   mode `0755` SMB mount before application health is accepted.

These are pre-deployment decisions, not reasons to redesign the released topology.
