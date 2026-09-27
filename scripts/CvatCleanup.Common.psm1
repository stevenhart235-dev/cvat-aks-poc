Set-StrictMode -Version Latest

$script:ExpectedClaims = [ordered]@{
    backend    = @{ name = 'cvat-backend-data'; driver = 'file.csi.azure.com'; storageClass = 'cvat-rwx' }
    postgresql = @{ name = 'data-cvat-postgresql-0'; driver = 'disk.csi.azure.com'; storageClass = 'cvat-rwo' }
    redis      = @{ name = 'redis-data-cvat-redis-master-0'; driver = 'disk.csi.azure.com'; storageClass = 'cvat-rwo' }
    kvrocks    = @{ name = 'cvat-kvrocks-data-cvat-kvrocks-0'; driver = 'disk.csi.azure.com'; storageClass = 'cvat-rwo' }
    clickhouse = @{ name = 'data-cvat-clickhouse-shard0-0'; driver = 'disk.csi.azure.com'; storageClass = 'cvat-rwo' }
}

function Get-CvatExpectedClaims { return $script:ExpectedClaims }

function Assert-CvatStorageInventory {
    param([Parameter(Mandatory)]$Claims, [Parameter(Mandatory)][string]$Namespace)

    $items = @($Claims)
    if ($items.Count -ne $script:ExpectedClaims.Count) { throw "Expected exactly five CVAT claims; found $($items.Count)." }
    foreach ($role in $script:ExpectedClaims.Keys) {
        $expected = $script:ExpectedClaims[$role]
        $matches = @($items | Where-Object { $_.pvc -eq $expected.name })
        if ($matches.Count -ne 1) { throw "Expected exactly one claim named $($expected.name)." }
        $claim = $matches[0]
        if ($claim.namespace -ne $Namespace -or $claim.role -ne $role) { throw "Claim identity mismatch for $role." }
        if ($claim.storageClass -ne $expected.storageClass) { throw "Unexpected StorageClass for $role." }
        if ($claim.driver -ne $expected.driver) { throw "Unexpected CSI driver for $role." }
        if ([string]::IsNullOrWhiteSpace($claim.pv) -or [string]::IsNullOrWhiteSpace($claim.volumeHandle)) { throw "Missing PV or CSI identity for $role." }
        if ($claim.reclaimPolicy -ne 'Retain') { throw "Expected Retain reclaim policy for $role." }
        if ($claim.claimRefNamespace -ne $Namespace -or $claim.claimRefName -ne $claim.pvc) { throw "PV claimRef mismatch for $role." }
        if ($claim.driver -eq 'file.csi.azure.com') {
            if ([string]::IsNullOrWhiteSpace($claim.resourceGroup) -or [string]::IsNullOrWhiteSpace($claim.storageAccount) -or [string]::IsNullOrWhiteSpace($claim.shareName)) { throw 'Azure Files identity is incomplete.' }
        } elseif ($claim.volumeHandle -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Compute/disks/[^/]+$') {
            throw "Azure Disk volume handle is not a managed-disk resource ID for $role."
        }
    }
    if (@($items.pv | Select-Object -Unique).Count -ne $items.Count) { throw 'Duplicate PV identity detected.' }
    if (@($items.volumeHandle | Select-Object -Unique).Count -ne $items.Count) { throw 'Duplicate CSI volume handle detected.' }
}

function Assert-CvatCleanupLedger {
    param([Parameter(Mandatory)]$Ledger)
    foreach ($field in 'subscriptionId','clusterResourceGroup','clusterName','nodeResourceGroup','namespace','releaseName','createdAtUtc') {
        if ([string]::IsNullOrWhiteSpace($Ledger.$field)) { throw "Ledger field $field is required." }
    }
    if ($Ledger.namespace -in @('default','kube-system')) { throw 'Refusing unsafe namespace.' }
    if ($Ledger.releaseName -ne 'cvat') { throw 'Only the cvat release is supported.' }
    Assert-CvatStorageInventory -Claims $Ledger.claims -Namespace $Ledger.namespace
}

Export-ModuleMember -Function Get-CvatExpectedClaims, Assert-CvatStorageInventory, Assert-CvatCleanupLedger
