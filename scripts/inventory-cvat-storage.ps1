[CmdletBinding()]
param(
    [string]$ClusterResourceGroup = 'rg-cvat-poc', [string]$ClusterName = 'aks-cvat-poc',
    [string]$Namespace = 'cvat', [string]$ReleaseName = 'cvat', [string]$LedgerPath, [string]$BaselinePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CvatCleanup.Common.psm1') -Force
if ([string]::IsNullOrWhiteSpace($LedgerPath)) { $LedgerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/cvat-cleanup-ledger.json' }
if ([string]::IsNullOrWhiteSpace($BaselinePath)) { $BaselinePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/cvat-storage-baseline.json' }
if (Test-Path -LiteralPath $LedgerPath) { throw "Ledger already exists at $LedgerPath. Refusing to overwrite it." }
if (-not (Test-Path -LiteralPath $BaselinePath)) { throw 'Pre-deployment storage baseline is absent; refusing an incomplete inventory.' }
$baseline = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json -Depth 100

$account = az account show -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $account.state -ne 'Enabled') { throw 'An enabled Azure CLI subscription is required.' }
$cluster = az aks show -g $ClusterResourceGroup -n $ClusterName -o json | ConvertFrom-Json -Depth 100
if ($LASTEXITCODE -ne 0 -or $cluster.provisioningState -ne 'Succeeded') { throw 'The expected AKS cluster is not ready.' }
if ($baseline.subscriptionId -ne $account.id -or $baseline.clusterName -ne $ClusterName -or $baseline.nodeResourceGroup -ne $cluster.nodeResourceGroup -or $baseline.namespace -ne $Namespace -or $baseline.releaseName -ne $ReleaseName) { throw 'Pre-deployment baseline scope does not match the live deployment.' }
$context = kubectl config current-context
if ($LASTEXITCODE -ne 0 -or $context -ne $ClusterName) { throw "kubectl context must be $ClusterName." }
$release = helm status $ReleaseName -n $Namespace -o json | ConvertFrom-Json -Depth 100
if ($LASTEXITCODE -ne 0 -or $release.name -ne $ReleaseName -or $release.namespace -ne $Namespace) { throw 'The expected Helm release was not found.' }

$allPvc = kubectl get pvc -n $Namespace -o json | ConvertFrom-Json -Depth 100
$allPv = kubectl get pv -o json | ConvertFrom-Json -Depth 100
if ($LASTEXITCODE -ne 0) { throw 'Unable to inventory PVCs and PVs.' }
$expected = Get-CvatExpectedClaims
$claims = @()
foreach ($role in $expected.Keys) {
    $definition = $expected[$role]
    $pvcMatches = @($allPvc.items | Where-Object { $_.metadata.name -eq $definition.name })
    if ($pvcMatches.Count -ne 1) { throw "Expected exactly one PVC $($definition.name)." }
    $pvc = $pvcMatches[0]
    $pvMatches = @($allPv.items | Where-Object { $_.metadata.name -eq $pvc.spec.volumeName })
    if ($pvMatches.Count -ne 1) { throw "Expected exactly one PV for PVC $($definition.name)." }
    $pv = $pvMatches[0]
    $entry = [ordered]@{
        role=$role; namespace=$Namespace; pvc=$pvc.metadata.name; pv=$pv.metadata.name
        storageClass=$pvc.spec.storageClassName; driver=$pv.spec.csi.driver; volumeHandle=$pv.spec.csi.volumeHandle
        reclaimPolicy=$pv.spec.persistentVolumeReclaimPolicy; claimRefNamespace=$pv.spec.claimRef.namespace
        claimRefName=$pv.spec.claimRef.name; resourceGroup=$null; storageAccount=$null; shareName=$null
    }
    if ($entry.driver -eq 'file.csi.azure.com') {
        $parts = @($entry.volumeHandle -split '#')
        if ($parts.Count -lt 3) { throw 'Unexpected Azure Files volume handle.' }
        $entry.resourceGroup=$parts[0]; $entry.storageAccount=$parts[1]; $entry.shareName=$parts[2]
    }
    $claims += [pscustomobject]$entry
}
$namespaceBoundPvs = @($allPv.items | Where-Object { $_.spec.claimRef.namespace -eq $Namespace })
if ($namespaceBoundPvs.Count -ne 5) { throw "Found unexpected PV claimRefs in namespace $Namespace." }
$ledger = [ordered]@{
    schemaVersion=1; createdAtUtc=(Get-Date).ToUniversalTime().ToString('o'); subscriptionId=$account.id
    clusterResourceGroup=$ClusterResourceGroup; clusterName=$ClusterName; nodeResourceGroup=$cluster.nodeResourceGroup
    namespace=$Namespace; releaseName=$ReleaseName; preexistingStorageAccountIds=@($baseline.storageAccountIds); claims=$claims
}
Assert-CvatCleanupLedger -Ledger ([pscustomobject]$ledger)
$directory = Split-Path -Parent $LedgerPath
if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$ledger | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $LedgerPath -Encoding utf8
Write-Host "Captured exactly five CVAT storage identities in the ignored cleanup ledger: $LedgerPath"
