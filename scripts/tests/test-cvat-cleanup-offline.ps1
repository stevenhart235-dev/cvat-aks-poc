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

function New-TestPod($Name, $Volumes) {
    [pscustomobject]@{
        metadata = [pscustomobject]@{ name = $Name; namespace = $namespace }
        spec = [pscustomobject]@{ volumes = $Volumes }
    }
}

$ledgeredPvc = [pscustomobject]@{ name='ledgered'; persistentVolumeClaim=[pscustomobject]@{ claimName='cvat-backend-data' } }
$otherPvc = [pscustomobject]@{ name='other'; persistentVolumeClaim=[pscustomobject]@{ claimName='unrelated-claim' } }
$configMap = [pscustomobject]@{ name='config'; configMap=[pscustomobject]@{ name='config' } }
$secret = [pscustomobject]@{ name='secret'; secret=[pscustomobject]@{ secretName='secret' } }
$emptyDir = [pscustomobject]@{ name='scratch'; emptyDir=[pscustomobject]@{} }
$projected = [pscustomobject]@{ name='service-account'; projected=[pscustomobject]@{ sources=@() } }
$malformedPvc = [pscustomobject]@{ name='malformed-pvc'; persistentVolumeClaim=[pscustomobject]@{} }
$missingSource = [pscustomobject]@{ name='missing-source' }
$claimNames = @($claims.pvc)

Assert-Throws { Assert-NoCvatClaimMounts -Pods @(New-TestPod 'ledgered-pvc' @($ledgeredPvc)) -Namespace $namespace -ClaimNames $claimNames } 'ledgered PVC mount'
Assert-NoCvatClaimMounts -Pods @(New-TestPod 'other-pvc' @($otherPvc)) -Namespace $namespace -ClaimNames $claimNames
Assert-NoCvatClaimMounts -Pods @(New-TestPod 'non-pvc' @($configMap,$secret,$emptyDir,$projected)) -Namespace $namespace -ClaimNames $claimNames
Assert-Throws { Assert-NoCvatClaimMounts -Pods @(New-TestPod 'mixed' @($configMap,$ledgeredPvc,$emptyDir)) -Namespace $namespace -ClaimNames $claimNames } 'ledgered PVC in mixed volumes'
Assert-NoCvatClaimMounts -Pods @(New-TestPod 'missing-pvc-property' @($configMap)) -Namespace $namespace -ClaimNames $claimNames
Assert-Throws { Assert-NoCvatClaimMounts -Pods @(New-TestPod 'malformed-pvc' @($malformedPvc)) -Namespace $namespace -ClaimNames $claimNames } 'malformed PVC source'
Assert-Throws { Assert-NoCvatClaimMounts -Pods @(New-TestPod 'missing-volume-source' @($missingSource)) -Namespace $namespace -ClaimNames $claimNames } 'missing volume source'
Write-Host 'PASS: cleanup ledger refusals and strict-mode pod-volume mount safety checks passed.'
