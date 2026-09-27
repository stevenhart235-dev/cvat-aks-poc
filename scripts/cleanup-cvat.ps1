[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ChartArchivePath,
    [string]$LedgerPath,
    [switch]$InventoryOnly,
    [string]$DestructiveConfirmation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CvatCleanup.Common.psm1') -Force
if ([string]::IsNullOrWhiteSpace($LedgerPath)) { $LedgerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/cvat-cleanup-ledger.json' }
if (-not (Test-Path -LiteralPath $LedgerPath)) { throw 'Cleanup ledger is absent; refusing unscoped cleanup.' }
if (-not (Test-Path -LiteralPath $ChartArchivePath)) { throw 'The approved local chart archive is required for the maintenance overlay.' }
$expectedArchiveSha256 = 'FE22AA4AA47CADD25991915DA8F120361131AFB98F8BD005D18D13B71836F2DA'
if ((Get-FileHash -LiteralPath $ChartArchivePath -Algorithm SHA256).Hash -ne $expectedArchiveSha256) { throw 'Chart archive SHA-256 does not match the approved CVAT 2.76.0 artifact.' }
$ledger = Get-Content -LiteralPath $LedgerPath -Raw | ConvertFrom-Json -Depth 100
Assert-CvatCleanupLedger -Ledger $ledger

$account = az account show -o json | ConvertFrom-Json
$cluster = az aks show -g $ledger.clusterResourceGroup -n $ledger.clusterName -o json | ConvertFrom-Json -Depth 100
$context = kubectl config current-context
if ($LASTEXITCODE -ne 0 -or $account.id -ne $ledger.subscriptionId -or $cluster.nodeResourceGroup -ne $ledger.nodeResourceGroup -or $context -ne $ledger.clusterName) { throw 'Live Azure subscription, cluster, node resource group, or kubectl context does not match the ledger.' }

function Get-LiveClaims {
    $allPvc = kubectl get pvc -n $ledger.namespace -o json | ConvertFrom-Json -Depth 100
    $allPv = kubectl get pv -o json | ConvertFrom-Json -Depth 100
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read live claims.' }
    $result = @()
    foreach ($captured in $ledger.claims) {
        $pvc = @($allPvc.items | Where-Object { $_.metadata.name -eq $captured.pvc })
        $pv = @($allPv.items | Where-Object { $_.metadata.name -eq $captured.pv })
        if ($pvc.Count -ne 1 -or $pv.Count -ne 1) { throw "Captured claim $($captured.role) is absent or ambiguous." }
        $result += [pscustomobject]@{role=$captured.role;namespace=$ledger.namespace;pvc=$pvc[0].metadata.name;pv=$pv[0].metadata.name;storageClass=$pvc[0].spec.storageClassName;driver=$pv[0].spec.csi.driver;volumeHandle=$pv[0].spec.csi.volumeHandle;reclaimPolicy=$pv[0].spec.persistentVolumeReclaimPolicy;claimRefNamespace=$pv[0].spec.claimRef.namespace;claimRefName=$pv[0].spec.claimRef.name;resourceGroup=$captured.resourceGroup;storageAccount=$captured.storageAccount;shareName=$captured.shareName}
    }
    $namespacePvs = @($allPv.items | Where-Object { $_.spec.claimRef.namespace -eq $ledger.namespace })
    if ($namespacePvs.Count -ne 5) { throw 'Unexpected PV claimRefs exist in the CVAT namespace.' }
    return $result
}

$liveClaims = @(Get-LiveClaims)
Assert-CvatStorageInventory -Claims $liveClaims -Namespace $ledger.namespace
foreach ($captured in $ledger.claims) {
    $live = @($liveClaims | Where-Object role -eq $captured.role)
    if ($live.Count -ne 1 -or $live[0].volumeHandle -ne $captured.volumeHandle -or $live[0].pv -ne $captured.pv) { throw "Live CSI identity differs from the ledger for $($captured.role)." }
}
Write-Host 'Inventory verified: five exact CVAT PVC/PV/CSI identities. StorageClasses are outside cleanup scope.'
if ($InventoryOnly) { return }
$required = "DELETE $($ledger.releaseName) FROM $($ledger.clusterName)/$($ledger.namespace)"
if ($DestructiveConfirmation -cne $required) { throw "Destructive confirmation must exactly equal: $required" }
if (-not $PSCmdlet.ShouldProcess("Helm release and five captured claims in $($ledger.namespace)", 'Remove CVAT and its captured backing storage')) { return }

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("cvat-cleanup-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    tar -xf $ChartArchivePath -C $temp
    if ($LASTEXITCODE -ne 0) { throw 'Unable to extract approved chart.' }
    $maintenance = Join-Path $temp 'cvat/values-maintenance.yaml'
    if (-not (Test-Path -LiteralPath $maintenance)) { throw 'Approved chart does not contain values-maintenance.yaml.' }
    helm upgrade $ledger.releaseName $ChartArchivePath -n $ledger.namespace --reuse-values -f $maintenance --wait --timeout 15m
    if ($LASTEXITCODE -ne 0) { throw 'Failed to quiesce CVAT with the packaged maintenance values.' }
    $jobs = kubectl get jobs -n $ledger.namespace -o json | ConvertFrom-Json -Depth 100
    if ($LASTEXITCODE -ne 0 -or @($jobs.items | Where-Object { $_.status.active -gt 0 }).Count -ne 0) { throw 'Active Jobs remain after quiescing CVAT.' }
    helm uninstall $ledger.releaseName -n $ledger.namespace --wait --timeout 15m
    if ($LASTEXITCODE -ne 0) { throw 'Helm uninstall failed.' }

    $pods = kubectl get pods -A -o json | ConvertFrom-Json -Depth 100
    Assert-NoCvatClaimMounts -Pods $pods.items -Namespace $ledger.namespace -ClaimNames @($ledger.claims.pvc)
    $liveClaims = @(Get-LiveClaims); Assert-CvatStorageInventory $liveClaims $ledger.namespace
    foreach ($claim in $liveClaims) {
        kubectl patch pv $claim.pv --type merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
        if ($LASTEXITCODE -ne 0) { throw "Failed to arm deletion for captured PV $($claim.pv)." }
    }
    foreach ($claim in $ledger.claims) {
        kubectl delete pvc $claim.pvc -n $ledger.namespace --wait=true
        if ($LASTEXITCODE -ne 0) { throw "Failed to delete captured PVC $($claim.pvc)." }
    }
    $deadline = (Get-Date).AddMinutes(15)
    foreach ($claim in $ledger.claims) {
        while ((kubectl get pv $claim.pv --ignore-not-found -o name) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
        if (kubectl get pv $claim.pv --ignore-not-found -o name) { throw "PV $($claim.pv) remains; stopping before any Azure cleanup." }
    }

    foreach ($claim in @($ledger.claims | Where-Object driver -eq 'disk.csi.azure.com')) {
        az resource show --ids $claim.volumeHandle --api-version 2024-03-02 -o none 2>$null
        if ($LASTEXITCODE -eq 0) { throw "Captured managed disk for $($claim.role) still exists." }
    }
    $file = @($ledger.claims | Where-Object driver -eq 'file.csi.azure.com')
    if ($file.Count -ne 1 -or $file[0].resourceGroup -ne $ledger.nodeResourceGroup) { throw 'Azure Files identity is ambiguous or outside the node resource group.' }
    $storageAccount = az storage account show -g $file[0].resourceGroup -n $file[0].storageAccount -o json 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0 -and $null -ne $storageAccount) {
        $shareId = "$($storageAccount.id)/fileServices/default/shares/$($file[0].shareName)"
        az resource show --ids $shareId --api-version 2023-05-01 -o none 2>$null
        if ($LASTEXITCODE -eq 0) { throw 'Captured Azure Files share still exists.' }
        if ($storageAccount.id -notin @($ledger.preexistingStorageAccountIds)) {
            $shares = az rest --method get --url "https://management.azure.com$($storageAccount.id)/fileServices/default/shares?api-version=2023-05-01" -o json | ConvertFrom-Json -Depth 100
            if ($LASTEXITCODE -ne 0 -or @($shares.value).Count -ne 0) { throw 'Test-created storage account is not proven empty; refusing deletion.' }
            az resource delete --ids $storageAccount.id --api-version 2023-05-01
            if ($LASTEXITCODE -ne 0) { throw 'Failed to delete the captured, new, empty storage account.' }
        }
    }
    kubectl delete namespace $ledger.namespace --wait=true
    if ($LASTEXITCODE -ne 0) { throw 'Failed to remove the empty CVAT namespace.' }
    foreach ($class in 'cvat-rwx','cvat-rwo') {
        if (-not (kubectl get storageclass $class -o name)) { throw "Platform StorageClass $class is missing after cleanup." }
    }
    Remove-Item -LiteralPath $LedgerPath
    Write-Host 'CVAT release, exact claims, PVs, and captured backing resources were removed; AKS and platform StorageClasses remain.'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
