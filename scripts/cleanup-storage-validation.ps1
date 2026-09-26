[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $repositoryRoot "artifacts/storage-validation-state.json"
if (-not (Test-Path -LiteralPath $statePath)) {
    throw "Cleanup ledger not found at $statePath. Refusing unscoped cleanup."
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 100
$activeSubscription = az account show --query id -o tsv
if ($LASTEXITCODE -ne 0 -or $activeSubscription -ne $state.subscriptionId) {
    throw "Azure subscription does not match the validation ledger."
}
$currentContext = kubectl config current-context
if ($LASTEXITCODE -ne 0 -or $currentContext -ne $state.clusterName) {
    throw "kubectl context does not match the validation ledger."
}

$rwx = $state.rwx
$rwo = $state.rwo
$livePvs = kubectl get pv -o json | ConvertFrom-Json -Depth 100
if ($LASTEXITCODE -ne 0) { throw "Failed to inventory live PVs." }
foreach ($pv in @($livePvs.items | Where-Object { $_.spec.claimRef.namespace -eq $state.namespace })) {
    if ($pv.spec.claimRef.name -notin @("rwx-test", "rwo-test")) {
        throw "Unexpected PV $($pv.metadata.name) refers to the validation namespace."
    }
    if ($pv.spec.csi.driver -eq "file.csi.azure.com" -and $null -eq $rwx) {
        $parts = @($pv.spec.csi.volumeHandle -split '#')
        if ($parts.Count -lt 3) { throw "Unexpected Azure Files volume handle: $($pv.spec.csi.volumeHandle)" }
        $rwx = [pscustomobject]@{
            pvc = $pv.spec.claimRef.name
            pv = $pv.metadata.name
            volumeHandle = $pv.spec.csi.volumeHandle
            resourceGroup = $parts[0]
            storageAccount = $parts[1]
            shareName = $parts[2]
        }
    }
    if ($pv.spec.csi.driver -eq "disk.csi.azure.com" -and $null -eq $rwo) {
        $rwo = [pscustomobject]@{
            pvc = $pv.spec.claimRef.name
            pv = $pv.metadata.name
            volumeHandle = $pv.spec.csi.volumeHandle
        }
    }
}

$pvNames = @()
if ($null -ne $rwx) { $pvNames += $rwx.pv }
if ($null -ne $rwo) { $pvNames += $rwo.pv }
foreach ($pvName in $pvNames) {
    if ([string]::IsNullOrWhiteSpace($pvName)) { continue }
    $existingPv = kubectl get pv $pvName --ignore-not-found -o name
    if ($LASTEXITCODE -ne 0) { throw "Failed to inspect PV $pvName." }
    if ($existingPv) {
        kubectl patch pv $pvName --type merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
        if ($LASTEXITCODE -ne 0) { throw "Failed to change test PV $pvName to Delete." }
    }
}

kubectl delete pods --all -n $state.namespace --ignore-not-found --wait=true
if ($LASTEXITCODE -ne 0) { throw "Failed to delete validation pods." }
kubectl delete pvc rwx-test rwo-test -n $state.namespace --ignore-not-found --wait=true
if ($LASTEXITCODE -ne 0) { throw "Failed to delete validation PVCs." }

$deadline = (Get-Date).AddMinutes(10)
foreach ($pvName in $pvNames) {
    while ((kubectl get pv $pvName --ignore-not-found -o name) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
    }
    if (kubectl get pv $pvName --ignore-not-found -o name) {
        throw "PV $pvName still exists; backing-resource deletion cannot be confirmed."
    }
}

kubectl delete namespace $state.namespace --ignore-not-found --wait=true
if ($LASTEXITCODE -ne 0) { throw "Failed to delete validation namespace." }

if ($null -ne $rwo) {
    az resource show --ids $rwo.volumeHandle --api-version 2024-03-02 -o none 2>$null
    if ($LASTEXITCODE -eq 0) { throw "Retained Azure disk still exists: $($rwo.volumeHandle)" }
}

if ($null -ne $rwx) {
    $account = az storage account show --resource-group $rwx.resourceGroup --name $rwx.storageAccount -o json 2>$null | ConvertFrom-Json
}
if ($null -ne $rwx -and $LASTEXITCODE -eq 0 -and $null -ne $account) {
    $shareId = "$($account.id)/fileServices/default/shares/$($rwx.shareName)"
    az resource show --ids $shareId --api-version 2023-05-01 -o none 2>$null
    if ($LASTEXITCODE -eq 0) { throw "Retained Azure file share still exists: $shareId" }

    $wasPreexisting = @($state.preexistingStorageAccountIds) -contains $account.id
    if (-not $wasPreexisting) {
        $shares = az rest --method get --url "https://management.azure.com$($account.id)/fileServices/default/shares?api-version=2023-05-01" -o json | ConvertFrom-Json -Depth 100
        if ($LASTEXITCODE -ne 0) { throw "Failed to enumerate shares in newly created account $($account.name)." }
        if (@($shares.value).Count -ne 0) {
            throw "New storage account $($account.name) contains shares and will not be deleted automatically."
        }
        az resource delete --ids $account.id --api-version 2023-05-01
        if ($LASTEXITCODE -ne 0) { throw "Failed to delete test-created empty storage account $($account.name)." }
    }
}

$remaining = kubectl get pods,pvc -A -l app.kubernetes.io/part-of=cvat-storage-validation -o name
if ($LASTEXITCODE -ne 0) { throw "Failed to verify Kubernetes cleanup." }
if ($remaining) { throw "Validation Kubernetes resources remain: $remaining" }

Remove-Item -LiteralPath $statePath
Write-Host "Storage validation cleanup completed and backing resources were verified absent."
