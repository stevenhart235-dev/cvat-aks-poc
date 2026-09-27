[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'CvatCleanup.Common.psm1') -Force

function Assert-Throws([scriptblock]$Action, [string]$Name) {
    try { & $Action; throw "Expected refusal did not occur: $Name" } catch {
        if ($_.Exception.Message -like 'Expected refusal did not occur:*') { throw }
    }
}

$subscription = '00000000-0000-0000-0000-000000000001'; $namespace = 'cvat'
$claims = @(
    [pscustomobject]@{role='backend';namespace=$namespace;pvc='cvat-backend-data';pv='pv-file';storageClass='cvat-rwx';driver='file.csi.azure.com';volumeHandle='MC_rg#account#share#id';reclaimPolicy='Retain';claimRefNamespace=$namespace;claimRefName='cvat-backend-data';resourceGroup='MC_rg';storageAccount='account';shareName='share'},
    [pscustomobject]@{role='postgresql';namespace=$namespace;pvc='data-cvat-postgresql-0';pv='pv-pg';storageClass='cvat-rwo';driver='disk.csi.azure.com';volumeHandle="/subscriptions/$subscription/resourceGroups/MC_rg/providers/Microsoft.Compute/disks/pg";reclaimPolicy='Retain';claimRefNamespace=$namespace;claimRefName='data-cvat-postgresql-0';resourceGroup=$null;storageAccount=$null;shareName=$null},
    [pscustomobject]@{role='redis';namespace=$namespace;pvc='redis-data-cvat-redis-master-0';pv='pv-redis';storageClass='cvat-rwo';driver='disk.csi.azure.com';volumeHandle="/subscriptions/$subscription/resourceGroups/MC_rg/providers/Microsoft.Compute/disks/redis";reclaimPolicy='Retain';claimRefNamespace=$namespace;claimRefName='redis-data-cvat-redis-master-0';resourceGroup=$null;storageAccount=$null;shareName=$null},
    [pscustomobject]@{role='kvrocks';namespace=$namespace;pvc='cvat-kvrocks-data-cvat-kvrocks-0';pv='pv-kv';storageClass='cvat-rwo';driver='disk.csi.azure.com';volumeHandle="/subscriptions/$subscription/resourceGroups/MC_rg/providers/Microsoft.Compute/disks/kv";reclaimPolicy='Retain';claimRefNamespace=$namespace;claimRefName='cvat-kvrocks-data-cvat-kvrocks-0';resourceGroup=$null;storageAccount=$null;shareName=$null},
    [pscustomobject]@{role='clickhouse';namespace=$namespace;pvc='data-cvat-clickhouse-shard0-0';pv='pv-ch';storageClass='cvat-rwo';driver='disk.csi.azure.com';volumeHandle="/subscriptions/$subscription/resourceGroups/MC_rg/providers/Microsoft.Compute/disks/ch";reclaimPolicy='Retain';claimRefNamespace=$namespace;claimRefName='data-cvat-clickhouse-shard0-0';resourceGroup=$null;storageAccount=$null;shareName=$null}
)
$ledger = [pscustomobject]@{subscriptionId=$subscription;clusterResourceGroup='rg-cvat-poc';clusterName='aks-cvat-poc';nodeResourceGroup='MC_rg';namespace=$namespace;releaseName='cvat';createdAtUtc='2026-01-01T00:00:00Z';claims=$claims}
Assert-CvatCleanupLedger $ledger
Assert-Throws { Assert-CvatStorageInventory @($claims | Select-Object -First 4) $namespace } 'missing claim'
$wrongDriver = @($claims | ForEach-Object { $_.PSObject.Copy() }); $wrongDriver[0].driver = 'disk.csi.azure.com'; Assert-Throws { Assert-CvatStorageInventory $wrongDriver $namespace } 'wrong driver'
$wrongRef = @($claims | ForEach-Object { $_.PSObject.Copy() }); $wrongRef[1].claimRefName = 'another-claim'; Assert-Throws { Assert-CvatStorageInventory $wrongRef $namespace } 'wrong claimRef'
$wrongClass = @($claims | ForEach-Object { $_.PSObject.Copy() }); $wrongClass[2].storageClass = 'default'; Assert-Throws { Assert-CvatStorageInventory $wrongClass $namespace } 'wrong class'
$duplicate = @($claims | ForEach-Object { $_.PSObject.Copy() }); $duplicate[4].volumeHandle = $duplicate[3].volumeHandle; Assert-Throws { Assert-CvatStorageInventory $duplicate $namespace } 'duplicate CSI identity'
$unsafe = $ledger.PSObject.Copy(); $unsafe.namespace = 'default'; Assert-Throws { Assert-CvatCleanupLedger $unsafe } 'unsafe namespace'
Write-Host 'PASS: valid ledger accepted and six ambiguity/scope/refusal cases rejected.'
