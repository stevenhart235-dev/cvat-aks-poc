# Milestone 2: CVAT application discovery

## Scope and source baseline

This document describes the upstream CVAT Community deployment model; it does not select
an AKS architecture, node size, or Azure storage product.

Research was performed on 2026-09-25 against upstream commit
[`f87f4a32`](https://github.com/cvat-ai/cvat/tree/f87f4a32dd13f031288e69c64304ac80d49284fd),
whose Helm chart reports version `2.76.1` and `appVersion: latest`. The primary sources are
the upstream [chart metadata](https://github.com/cvat-ai/cvat/blob/f87f4a32dd13f031288e69c64304ac80d49284fd/helm-chart/Chart.yaml),
[default values](https://github.com/cvat-ai/cvat/blob/f87f4a32dd13f031288e69c64304ac80d49284fd/helm-chart/values.yaml),
[templates](https://github.com/cvat-ai/cvat/tree/f87f4a32dd13f031288e69c64304ac80d49284fd/helm-chart/templates),
and [official Helm deployment guide](https://docs.cvat.ai/docs/administration/community/advanced/k8s_deployment_with_helm/).

The labels used below are deliberate:

- **Upstream fact**: behavior stated by CVAT documentation or application code.
- **Chart observation**: behavior rendered from the current Helm chart and pinned dependencies.
- **POC implication**: an inference to validate later, not a final design decision.

## Current component map

| Component | Kubernetes form and default | Purpose and state boundary |
| --- | --- | --- |
| Frontend | Deployment, 1 replica; ClusterIP on 8000 | Static/UI web tier. No default persistent volume. |
| Backend server | Deployment, 1 replica, two containers (`server` and nginx); ClusterIP on 8080 | REST/API and synchronous application path. Mounts shared backend data. |
| Initializer | One Job per Helm revision | Runs backend `init`, including database initialization/migrations. It is not a long-running service. |
| Export worker | Deployment, 2 replicas, 1 process each | Handles the `export` queue and scheduler; mounts shared backend data. |
| Import worker | Deployment, 2 replicas, 1 process each | Handles task/data imports and task creation; mounts shared backend data. |
| Annotation worker | Deployment, 1 replica, 1 process | Handles automatic-annotation queue work; mounts shared backend data. |
| Chunks worker | Deployment, 2 replicas, 1 process each | Generates/serves prepared media chunks; mounts shared backend data. |
| Webhooks worker | Deployment, 1 replica, 1 process | Delivers webhooks; no backend PVC mount in the template. |
| Quality-reports worker | Deployment, 1 replica, 1 process | Computes quality reports; no backend PVC mount in the template. |
| Consensus worker | Deployment, 1 replica, 1 process | Computes consensus operations; no backend PVC mount in the template. |
| Utils worker | Deployment, 1 replica, 1 process | Runs notifications and cleaning queues/schedules; mounts shared backend data. |
| OPA | Deployment, 1 replica; ClusterIP on 8181 | Authorization policy engine. Polls policy bundles from the backend. No persistent volume. |
| PostgreSQL | Pinned Bitnami subchart; StatefulSet, 1 replica | Authoritative relational application metadata: users, projects, tasks, jobs, annotations, and related records. |
| Redis | Pinned Bitnami subchart; standalone StatefulSet, 1 replica | In-memory Redis endpoint used for RQ queues and application cache. Persistence is enabled by the rendered dependency defaults. |
| KVrocks | CVAT StatefulSet, 1 replica; ClusterIP on 6666 | Redis-compatible on-disk store configured as `CVAT_REDIS_ONDISK`; persistent by default. |
| Vector | Dependency StatefulSet, 1 replica | Receives CVAT event/log traffic and forwards it to ClickHouse. The rendered default has no PVC. |
| ClickHouse | Pinned Bitnami subchart; one shard/one-replica StatefulSet | Stores analytics/events, separate from PostgreSQL application metadata. |
| Grafana | Dependency Deployment, 1 replica | Presents CVAT analytics dashboards backed by ClickHouse. Persistence is not enabled in the rendered default. |
| Nuclio | Optional dependency; disabled by default | Deploys/manages serverless inference functions when explicitly enabled. |
| Traefik | Optional dependency; disabled in raw `values.yaml` | Possible ingress controller; not intrinsic to the CVAT application. |

**Chart observation:** all core CVAT Deployments use `Recreate`, including worker
Deployments whose default replica count is greater than one. This avoids overlapping old
and new pods during upgrades but creates an availability interruption for that component.

## Request and data flow

```text
Client
  |
  v
Ingress (optional; one hostname)
  |-- /api, /admin, /static, /django-rq, /profiler --> backend Service --> nginx --> server
  `-- /                                              --> frontend Service

Backend server
  |-- policy decisions ------------------------------> OPA
  |-- relational metadata ---------------------------> PostgreSQL
  |-- queues/cache -----------------------------------> Redis
  |-- durable Redis-compatible data -----------------> KVrocks
  |-- async jobs via Redis --------------------------> specialized workers
  |-- uploaded/prepared media, caches, keys, logs ---> shared backend filesystem
  |-- source/export objects -------------------------> attached cloud storage (optional)
  |-- events/logs ------------------------------------> Vector --> ClickHouse --> Grafana
  `-- model discovery/invocation, when enabled ------> Nuclio --> function pods
```

**Upstream fact:** CVAT uses distinct RQ queues for import, export, automatic annotation,
webhooks, notifications, quality reports, cleaning, chunks, and consensus. Import/export
jobs permit long execution windows (four hours by default), and automatic annotation can
run for up to 24 hours. Queue separation is an explicit scaling boundary in the application.

## Default Helm deployment characteristics

### Workloads and replicas

The chart renders these core CVAT objects by default:

- 11 Deployments: frontend, backend server, OPA, and eight specialized worker
  Deployments.
- One initializer Job.
- One KVrocks StatefulSet.
- Dependency workloads for PostgreSQL, Redis, Vector, ClickHouse, and Grafana.
- No Nuclio resources unless `nuclio.enabled=true`.

The total default CVAT backend worker replica count is 11: export 2, import 2, chunks 2,
and one each for annotation, webhooks, quality reports, consensus, and utils. Each worker
defaults to one process (`numProcs: 1`).

### Resources and scheduling

**Chart observation:** core CVAT `resources` maps are empty. The default render therefore
sets no CPU or memory requests or limits for frontend, backend, workers, initializer, OPA,
or KVrocks. Capacity requirements cannot be derived from the chart alone.

Core templates expose:

- shared backend-level plus per-component `affinity` and `tolerations`;
- per-component extra environment variables, volumes, and mounts;
- frontend and OPA affinity/tolerations;
- KVrocks affinity, tolerations, and a separate `nodeAffinity` value.

**Chart observation:** the current core templates do not expose a direct `nodeSelector`
value. Required node placement can still be expressed through affinity, but this should be
tested against the exact chart artifact selected later. Dependency charts have their own
scheduling settings.

### Health probes

- Backend server readiness and liveness are HTTP probes against `/api/server/about` on
  the nginx sidecar, enabled by default.
- Frontend readiness and liveness use TCP port 8000.
- OPA readiness and liveness use `/health?bundles`, so health includes successful policy
  bundle loading from CVAT rather than only process availability.
- KVrocks uses `redis-cli PING` exec probes.
- Workers have an enabled liveness exec probe (`django-admin workerprobe`) but no
  readiness probe in the templates.
- The initializer Job has no probe.

### Services and ingress

CVAT backend, frontend, OPA, KVrocks, and the bundled data services are ClusterIP services
by default. The CVAT Ingress uses one hostname and routes backend paths (`/api`, `/admin`,
`/static`, `/django-rq`, `/profiler`) separately from the frontend catch-all `/` path.
Ingress TLS is optional and expects an existing TLS Secret.

**Chart observation:** raw `values.yaml` disables both Ingress and Traefik, while
`cvat.values.yaml` enables both and the official guide describes Traefik ingress as enabled
by default. The exact OCI chart/version and its effective packaged values must be rendered
before Milestone 3; source-tree install behavior and packaged-chart behavior should not be
assumed identical.

## State and storage map

| State | Default persistence/access | Consumers | Classification |
| --- | --- | --- | --- |
| Backend `/home/django/data`, `/keys`, `/logs` | One retained 20 GiB PVC, `ReadWriteMany` | Server; annotation, import, export, chunks, and utils workers | CVAT application media/cache/runtime state |
| PostgreSQL | 8 GiB `ReadWriteOnce` claim | Backend and workers | Authoritative application metadata |
| Redis | 8 GiB `ReadWriteOnce` claim | Backend and all RQ workers | Queues/cache; operational state |
| KVrocks | 100 GiB `ReadWriteOnce` claim | Backend and workers through Redis protocol | On-disk operational/application state |
| ClickHouse | 8 GiB `ReadWriteOnce` claim | Vector/Grafana/backend analytics | Analytics/event state, not primary task metadata |
| Vector | No PVC in default render | Backend event stream | Ephemeral forwarding/buffering boundary unless overridden |
| Grafana | No PVC in default render | Users viewing analytics | Dashboard service; chart-provisioned configuration |
| External/cloud source data | Outside CVAT PVCs | Import/chunks/server paths as needed | User dataset source, potentially authoritative outside CVAT |

### What `/home/django/data` contains

**Upstream fact:** CVAT documents this path as uploaded and prepared media data. Current
application settings create subtrees for media data, caches (including export cache), jobs,
tasks, projects, assets, cloud-storage working data, and temporary files. The same chart PVC
also carries separate `keys` and `logs` subpaths. The Django secret key is durable state;
logs are operational data rather than authoritative annotation metadata.

**Chart observation:** the chart intentionally requests RWX because several independently
scheduled Deployments and multiple replicas mount the same claim. RWO is sufficient for
the single-replica PostgreSQL, Redis, KVrocks, and ClickHouse StatefulSets, but a normal
single-node RWO backend disk would not preserve the current multi-pod/multi-node sharing
model.

**POC implication:** shared backend storage is an application requirement under the
current chart, not merely a convenience. Whether all subpaths truly need one RWX volume,
and whether logs/keys/cache should be separated, is a later design question.

The backend PVC has `helm.sh/resource-policy: keep`, so Helm uninstall does not normally
remove it. Backup scope must include PostgreSQL plus backend media/state; analytics recovery
also requires ClickHouse if event history matters. Redis and KVrocks recovery requirements
need workload-specific testing rather than assuming they are disposable caches.

## Dataset storage behavior

**Upstream facts:**

- Browser/client uploads and copied server-share inputs become CVAT-local uploaded or
  prepared media under the backend data root.
- CVAT can attach Amazon S3/S3-compatible, Azure Blob Storage, and Google Cloud Storage
  and use them as task import/export sources.
- Server-share inputs can be copied into CVAT or referenced from the share, depending on
  task options.
- Cloud-backed tasks can retain a cloud-storage location rather than copying every source
  object into the local upload directory. Lightweight backups for such tasks omit raw media.
- “Data on the fly” records minimal metadata, creates requested chunks lazily, and stores
  generated chunks in a bounded cache. First access is slower; source data must remain
  reachable; some videos fall back to eager chunk generation.
- Dataset manifests improve discovery and random access but do not eliminate all media
  processing or caching.

See the official [cloud storage guide](https://docs.cvat.ai/docs/workspace/attach-cloud-storage/),
[data-on-the-fly description](https://docs.cvat.ai/docs/dataset_management/data-on-fly/),
and [backup behavior](https://docs.cvat.ai/docs/dataset_management/backup/).

**POC implication:** datasets measured in tens or hundreds of terabytes should not be
assumed to fit, or need to fit, in the chart's 20 GiB backend claim. The important boundary
is between the authoritative external source dataset and CVAT's metadata, generated chunks,
caches, uploads, exports, and temporary working space. Milestone 3 must validate a
cloud-backed task experimentally before extrapolating to very large collections.

## Scaling boundaries

### Independently scalable

- Frontend replicas.
- Backend server replicas, subject to shared storage and database/cache dependencies.
- Each worker type independently through `replicas` and `numProcs`.
- OPA replicas.
- Analytics components through their dependency-chart controls.
- Nuclio function workloads independently of normal CVAT workers.

### Work likely to drive capacity

This is an application-code inference to validate with measurements:

- Import/task creation: decoding, validation, extraction, media preparation, and writes.
- Chunk generation: image/video decoding and encoding; CPU, memory, storage throughput,
  and source-storage latency.
- Export: archive creation, format conversion, temporary space, and network transfer.
- Quality and consensus jobs: data-dependent CPU/memory usage.
- Automatic annotation: orchestration and image transfer in CVAT; model compute in the
  invoked function/agent.
- PostgreSQL, Redis/KVrocks, and shared-storage latency can become cross-worker bottlenecks
  even when worker replicas increase.

Multiple replicas of server, import, export, annotation, chunks, and utils retain the
shared-storage requirement because those templates mount the same backend PVC. Webhook,
quality-report, and consensus workers do not mount it in the current templates, although
they still share PostgreSQL and Redis/KVrocks dependencies.

No HorizontalPodAutoscaler is created by the chart. Replica and process counts are static
unless another controller or operator is added.

## GPU and inference boundary

**Upstream fact:** normal CVAT frontend, API, media workers, databases, OPA, and analytics
do not request or require GPUs in the Helm chart.

Nuclio is disabled by default. When enabled, shared backend environment enables CVAT's
serverless integration and points CVAT at the Nuclio dashboard/function namespace. CVAT
discovers and invokes model functions over the Nuclio interface; inference executes in the
separate function pods, not in the normal CVAT server or worker containers. Official GPU
function definitions request resources such as `nvidia.com/gpu: 1` and use GPU-capable
runtime images. See the official
[serverless tutorial](https://docs.cvat.ai/docs/guides/serverless-tutorial/) and
[GPU function examples](https://github.com/cvat-ai/cvat/tree/f87f4a32dd13f031288e69c64304ac80d49284fd/serverless).

CVAT also has an agent model in which separately deployed agents poll CVAT for work; the
official [Helm agent guide](https://docs.cvat.ai/docs/guides/helm-agents-userguide/) states
that GPU agents require the NVIDIA device plugin and GPU resources on their nodes.

**POC implication:** GPU infrastructure can remain absent from the main CVAT application
pool and can later be isolated using scheduling controls on function/agent workloads. The
exact Nuclio scheduling customization and networking path must be proven before selecting
a GPU-node design.

## External dependency boundaries

The chart already supports disabling bundled PostgreSQL and Redis and supplying external
hosts. KVrocks has an enabled/external-host switch. Analytics accepts an external
ClickHouse host when its bundled chart is disabled. These are clean logical boundaries for
future evaluation of managed or separately operated services:

- PostgreSQL: relational system of record.
- Redis: RQ broker and in-memory cache.
- KVrocks: Redis-compatible on-disk service.
- ClickHouse: analytics/event store.
- Dataset object storage: supported external source/export boundary.

Vector, Grafana, OPA, ingress, and Nuclio are application/platform components rather than
straight database substitutions. This milestone makes no recommendation to replace any
bundled dependency.

## Kubernetes requirements discovered

1. A schedulable application pool: the current cluster's system-only taint intentionally
   prevents these workloads from landing there.
2. A shared RWX backend filesystem for the chart as written, plus independent RWO claims
   for bundled stateful dependencies.
3. Dynamic volume provisioning and a deliberate reclaim/backup policy.
4. Enough CPU/memory for a high default pod count despite the absence of resource requests.
5. Ingress capable of path routing to frontend and backend services, with upload/request
   size and timeout behavior suitable for large transfers and long operations.
6. Reliable outbound access to image registries and any attached cloud/object storage;
   private endpoints may require explicit outbound-proxy allowances.
7. Stable internal DNS and service connectivity among backend, OPA, Redis, KVrocks,
   PostgreSQL, and optional analytics/serverless services.
8. Scheduling policy expressed through affinity/tolerations for current core templates.
9. Secret management for database/cache credentials, Django key material, cloud-storage
   credentials, and TLS.
10. GPU device-plugin and GPU-node scheduling only if separate inference functions or
    agents are introduced.

## Open questions

- Which released OCI chart and matching CVAT image tags should the POC pin instead of
  `develop`, `dev`, and `latest`?
- What are the effective packaged defaults for Ingress/Traefik in that exact artifact?
- Can analytics be disabled cleanly for the selected release, and is it required for the
  evaluation goals?
- Which backend subpaths require durable backup, which are regenerable caches, and can the
  Django key be supplied separately from the RWX volume?
- What storage semantics and performance are required by concurrent import/export/chunk
  workers, beyond the chart's RWX declaration?
- Is bundled Redis persistence operationally required for the POC, and what distinct data
  is retained in KVrocks across the target workflows?
- How does CVAT behave when a worker dies mid-job, and which queues are safe to scale above
  their defaults?
- What ingress body-size, buffering, and timeout limits are needed for representative
  uploads, exports, and API calls?
- Which cloud-storage authentication modes can use workload identity rather than stored
  credentials in the selected CVAT release?
- Does a cloud-backed, on-demand task avoid full source duplication for our representative
  image and video formats, and how large does its generated cache become?
- Should Nuclio, CVAT agents, or neither be used for the inference scenarios under study?

## Initial implications for the AKS POC

These are inputs to Milestone 3, not a final architecture:

1. Add an application scheduling boundary before deployment; retain the system-only pool.
2. Pin and render a released CVAT chart and matching images before creating manifests or
   sizing capacity.
3. Decide whether the first deployment includes bundled analytics and Nuclio; Nuclio is
   already off by default, while analytics is on in current source defaults.
4. Establish a storage experiment covering backend RWX semantics and the four bundled RWO
   claims without yet selecting an Azure product.
5. Treat PostgreSQL and backend media/state as separate backup domains.
6. Start with explicit, conservative requests/limits because upstream supplies none, then
   measure import, chunk generation, export, and annotation behavior.
7. Test external/cloud-backed data with manifests and data-on-the-fly using a representative
   dataset; do not size cluster storage from total source-dataset capacity alone.
8. Keep GPU capacity out of the base CVAT deployment. Add it only with a chosen and tested
   serverless/agent inference path.
9. Validate ingress routing and large-transfer behavior independently of CVAT component
   health.
10. Capture queue depth, job duration, CPU, memory, network, and storage throughput during
    the first application experiment; these measurements should drive later scaling.
