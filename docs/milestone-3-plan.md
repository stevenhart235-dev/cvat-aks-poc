# Milestone 3: CVAT CPU platform baseline

Milestone 3 established and proved the smallest useful application platform for a later
CVAT deployment and measurement exercise. It is a functional baseline, not a production
sizing exercise. The platform was validated and then destroyed cleanly; this document
preserves the design rationale, implemented configuration, and measured results needed to
recreate it.

## Application requirements carried forward

- CVAT backend pods require shared `ReadWriteMany` storage.
- Bundled PostgreSQL, Redis, KVrocks, and ClickHouse require independent
  `ReadWriteOnce` volumes.
- The released chart has no useful default CPU or memory requests or limits.
- CVAT components must not schedule onto the system-only node pool.
- Import, chunk-generation, and export workloads require enough headroom to produce useful
  measurements instead of beginning from a CPU-saturated baseline.

Production dataset capacity and retention requirements remain unknown. Milestone 3 did not
assume a production data volume or design long-term dataset storage. Representative CVAT
dataset workflows and cloud-backed datasets are intentionally deferred to application
deployment work.

## Planned design and rationale

- A fixed two-node user pool using `Standard_D4as_v7`.
- Node label `workload=cvat` and taint `workload=cvat:NoSchedule`.
- No autoscaling and no GPU nodes.
- Azure Disk CSI for stateful `ReadWriteOnce` claims.
- Azure File CSI for the shared backend `ReadWriteMany` claim.
- Explicit `cvat-rwo` and `cvat-rwx` StorageClasses with retained backing storage.

Together with the two-vCPU system node, the application pool consumes the subscription's
current ten-vCPU regional and Dasv7-family quota. Milestone 3 accepts that there is no
capacity for surge nodes or scale-out, and does not request a quota increase. Full-topology
survival after cordoning one application node is not a success criterion; representative
pod rescheduling and cross-node storage access are. Terraform explicitly records Azure's
default `max_surge = "10%"` for the application pool to avoid provider/default drift; this
does not make surge upgrades viable while quota usage remains ten of ten vCPUs.

## Intentionally deferred application measurements

Analytics is an optional CVAT application capability to measure rather than a permanent
platform assumption:

1. Establish the first baseline with analytics enabled, matching the released defaults.
2. Repeat the baseline with analytics disabled.
3. Record the difference in pod count, requested and observed CPU and memory, persistent
   storage, and application behavior.

## Implemented configuration boundary

This platform step created the application node pool and enabled the required CSI drivers.
The StorageClass manifests define the storage interfaces CVAT can consume later. Milestone
3 did not deploy CVAT, create application PVCs, or choose a production storage and
retention architecture.

## Proven platform status

Milestone 3 was deployed and validated successfully as a CPU and storage platform baseline.
The measured platform is:

- AKS Kubernetes `1.35.8`.
- One `Standard_D2as_v7` system node, with `1900m` CPU, `5928364Ki` memory, and
  250 pods allocatable.
- Two `Standard_D4as_v7` CVAT application nodes. Each node has `3860m` CPU,
  `12075760Ki` memory, and 250 pods allocatable.
- Measured CVAT-node DaemonSet requests of `310m` CPU and `576 MiB` memory per
  node.
- Healthy Azure Disk CSI and Azure File CSI components and node-driver
  registrations.
- Installed `cvat-rwo` and `cvat-rwx` StorageClasses.

The deployed node pools consume 10 of 10 available regional and Dasv7-family
vCPUs. Autoscaling, scale-out, and surge capacity remain unavailable without a
quota increase or a deliberate reduction in running capacity.

## Storage validation evidence

The storage validation dynamically provisioned one Azure Files RWX volume and
one Azure Disk RWO volume. Two RWX test pods were constrained to different CVAT
nodes. Each pod successfully read data written by the other, proving cross-node
read/write access. The mounted directory and marker files were observed as
UID/GID `1000:1000` with mode `0755`. RWX data remained available after deleting
and recreating one test pod.

The RWO test pod wrote marker data, was deleted, and then successfully remounted
the same volume after recreation with its data intact. The recreated pod ran on
the same node, so cross-node disk detach/reattach was not tested and remains a
separate experiment if later required.

Cleanup changed only the two test PVs from `Retain` to `Delete`, then removed the
test pods, claims, volumes, namespace, managed disk, file share, and the empty
test-created storage account. The platform StorageClasses and AKS resources
remained healthy. A final Terraform drift check reported zero changes.

During the first validation run, the RWX recreation assertion concatenated two
marker files without newline delimiters. The shared storage contained the correct
data; only the assertion's output parsing was wrong. The script was minimally
corrected to delimit and validate both values explicitly, cleanup completed, and
the full validation was rerun successfully from a clean state.
