# Storage validation

This package validates the two Milestone 3 storage interfaces without deploying CVAT.
It is intentionally not applied as part of Terraform.

The validation script performs these checks:

- applies the `cvat-rwx` and `cvat-rwo` StorageClasses;
- dynamically provisions one small claim for each class;
- pins two RWX pods to different Ready nodes labeled `workload=cvat`;
- verifies bidirectional cross-node reads and writes, UID/GID 1000, projected mode 0755,
  and persistence after recreating an RWX pod;
- verifies RWO provisioning and successful attachment, then proves that marker data
  survives pod deletion and recreation by remounting and reusing the existing PVC on the
  same pinned application node;
- records PVC, PV, CSI handle, and Azure backing-resource information in the ignored
  `artifacts/storage-validation-state.json` cleanup ledger.

Run from the repository root only after reviewing the active Azure and Kubernetes contexts:

```powershell
./scripts/validate-storage.ps1
```

The StorageClasses use `Retain`, so deleting claims directly would intentionally leave their
backing resources behind. The cleanup script first changes only the two captured test PVs to
`Delete`, removes the test workloads and claims, waits for CSI deletion, and verifies that
the Azure disk and file share are gone. If Azure File CSI created a new storage account for
the test, cleanup deletes that account only when it was absent before validation, matches
the captured share account, and contains no remaining shares.

```powershell
./scripts/cleanup-storage-validation.ps1
```

The cleanup retains `cvat-rwx` and `cvat-rwo` because they are platform StorageClasses for
the later CVAT deployment. It must finish successfully before the storage validation is
considered complete.

This validation does not test cross-node Azure Disk detach/reattach. The recreated RWO pod
is intentionally pinned to the same application node; cross-node behavior is deferred
unless a later availability requirement makes it relevant.
