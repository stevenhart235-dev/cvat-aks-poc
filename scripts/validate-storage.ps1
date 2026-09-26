[CmdletBinding()]
param(
    [string]$ClusterResourceGroup = "rg-cvat-poc",
    [string]$ClusterName = "aks-cvat-poc"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$storageClassPath = Join-Path $repositoryRoot "kubernetes/platform/storage-classes.yaml"
$validationPath = Join-Path $repositoryRoot "kubernetes/validation/storage"
$stateDirectory = Join-Path $repositoryRoot "artifacts"
$statePath = Join-Path $stateDirectory "storage-validation-state.json"
$namespace = "cvat-storage-validation"

function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Native command failed with exit code $LASTEXITCODE."
    }
}

function Apply-Template {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$NodeName
    )

    $rendered = (Get-Content -LiteralPath $Path -Raw).Replace("__NODE_NAME__", $NodeName)
    $rendered | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply template $Path."
    }
}

if (Test-Path -LiteralPath $statePath) {
    throw "Cleanup ledger already exists at $statePath. Run cleanup before another validation."
}

$account = az account show -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $account.state -ne "Enabled") {
    throw "An enabled Azure CLI subscription is required."
}

$cluster = az aks show --resource-group $ClusterResourceGroup --name $ClusterName -o json | ConvertFrom-Json -Depth 100
if ($LASTEXITCODE -ne 0 -or $cluster.provisioningState -ne "Succeeded") {
    throw "AKS cluster $ClusterName is not ready."
}

$currentContext = kubectl config current-context
if ($LASTEXITCODE -ne 0 -or $currentContext -ne $ClusterName) {
    throw "kubectl context must be $ClusterName; current context is $currentContext."
}

$existingNamespace = kubectl get namespace $namespace --ignore-not-found -o name
if ($LASTEXITCODE -ne 0) { throw "Failed to check validation namespace." }
if ($existingNamespace) { throw "Namespace $namespace already exists. Run cleanup before validation." }

$nodeList = kubectl get nodes -l workload=cvat -o json | ConvertFrom-Json -Depth 100
if ($LASTEXITCODE -ne 0) { throw "Failed to list CVAT nodes." }
$readyNodes = @($nodeList.items | Where-Object {
    @($_.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" }).Count -eq 1
} | Sort-Object { $_.metadata.name })
if ($readyNodes.Count -ne 2) {
    throw "Expected exactly two Ready workload=cvat nodes; found $($readyNodes.Count)."
}

New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
$preexistingAccounts = @(az storage account list --resource-group $cluster.nodeResourceGroup -o json | ConvertFrom-Json | ForEach-Object { $_.id })
if ($LASTEXITCODE -ne 0) { throw "Failed to inventory pre-existing storage accounts." }

$ledger = [ordered]@{
    subscriptionId = $account.id
    clusterResourceGroup = $ClusterResourceGroup
    clusterName = $ClusterName
    nodeResourceGroup = $cluster.nodeResourceGroup
    namespace = $namespace
    nodes = @($readyNodes.metadata.name)
    preexistingStorageAccountIds = $preexistingAccounts
    rwx = $null
    rwo = $null
}
$ledger | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8

Invoke-Native { kubectl apply -f $storageClassPath }
Invoke-Native { kubectl apply -f (Join-Path $validationPath "namespace-and-claims.yaml") }

$nodeA = $readyNodes[0].metadata.name
$nodeB = $readyNodes[1].metadata.name
Apply-Template -Path (Join-Path $validationPath "rwx-a.yaml.tpl") -NodeName $nodeA
Apply-Template -Path (Join-Path $validationPath "rwx-b.yaml.tpl") -NodeName $nodeB
Apply-Template -Path (Join-Path $validationPath "rwo.yaml.tpl") -NodeName $nodeA

Invoke-Native { kubectl wait --namespace $namespace --for=condition=Ready pod/rwx-a pod/rwx-b pod/rwo --timeout=10m }

$actualA = kubectl get pod rwx-a -n $namespace -o jsonpath='{.spec.nodeName}'
$actualB = kubectl get pod rwx-b -n $namespace -o jsonpath='{.spec.nodeName}'
if ($LASTEXITCODE -ne 0 -or $actualA -ne $nodeA -or $actualB -ne $nodeB -or $actualA -eq $actualB) {
    throw "RWX pods were not placed on the two expected distinct CVAT nodes."
}

Invoke-Native { kubectl exec -n $namespace rwx-a -- sh -c 'printf from-a > /data/from-a && sync' }
$fromA = kubectl exec -n $namespace rwx-b -- cat /data/from-a
if ($LASTEXITCODE -ne 0 -or $fromA -ne "from-a") { throw "Pod B could not read Pod A's marker." }
Invoke-Native { kubectl exec -n $namespace rwx-b -- sh -c 'printf from-b > /data/from-b && sync' }
$fromB = kubectl exec -n $namespace rwx-a -- cat /data/from-b
if ($LASTEXITCODE -ne 0 -or $fromB -ne "from-b") { throw "Pod A could not read Pod B's marker." }

$modeOutput = kubectl exec -n $namespace rwx-a -- stat -c '%u:%g %a %n' /data /data/from-a /data/from-b
if ($LASTEXITCODE -ne 0) { throw "Failed to inspect RWX ownership and modes." }
$modeOutput | ForEach-Object {
    if ($_ -notmatch '^1000:1000 755 ') { throw "Unexpected RWX ownership or mode: $_" }
}

Invoke-Native { kubectl delete pod rwx-b -n $namespace --wait=true }
Apply-Template -Path (Join-Path $validationPath "rwx-b.yaml.tpl") -NodeName $nodeB
Invoke-Native { kubectl wait --namespace $namespace --for=condition=Ready pod/rwx-b --timeout=5m }
$afterRecreate = @(kubectl exec -n $namespace rwx-b -- sh -c 'cat /data/from-a; printf "\n"; cat /data/from-b; printf "\n"')
if ($LASTEXITCODE -ne 0 -or $afterRecreate.Count -ne 2 -or $afterRecreate[0] -ne 'from-a' -or $afterRecreate[1] -ne 'from-b') {
    throw "RWX data did not persist across Pod B recreation."
}

Invoke-Native { kubectl exec -n $namespace rwo -- sh -c 'printf rwo-marker > /data/marker && sync' }
Invoke-Native { kubectl delete pod rwo -n $namespace --wait=true }
Apply-Template -Path (Join-Path $validationPath "rwo.yaml.tpl") -NodeName $nodeA
Invoke-Native { kubectl wait --namespace $namespace --for=condition=Ready pod/rwo --timeout=10m }
$rwoMarker = kubectl exec -n $namespace rwo -- cat /data/marker
if ($LASTEXITCODE -ne 0 -or $rwoMarker -ne "rwo-marker") {
    throw "RWO marker did not persist across pod recreation and disk reattachment."
}

$rwxPvc = kubectl get pvc rwx-test -n $namespace -o json | ConvertFrom-Json -Depth 100
$rwoPvc = kubectl get pvc rwo-test -n $namespace -o json | ConvertFrom-Json -Depth 100
$rwxPv = kubectl get pv $rwxPvc.spec.volumeName -o json | ConvertFrom-Json -Depth 100
$rwoPv = kubectl get pv $rwoPvc.spec.volumeName -o json | ConvertFrom-Json -Depth 100
if ($LASTEXITCODE -ne 0) { throw "Failed to capture PV information." }

$fileParts = @($rwxPv.spec.csi.volumeHandle -split '#')
if ($fileParts.Count -lt 3) { throw "Unexpected Azure Files volume handle: $($rwxPv.spec.csi.volumeHandle)" }
$ledger.rwx = [ordered]@{
    pvc = $rwxPvc.metadata.name
    pv = $rwxPv.metadata.name
    volumeHandle = $rwxPv.spec.csi.volumeHandle
    resourceGroup = $fileParts[0]
    storageAccount = $fileParts[1]
    shareName = $fileParts[2]
}
$ledger.rwo = [ordered]@{
    pvc = $rwoPvc.metadata.name
    pv = $rwoPv.metadata.name
    volumeHandle = $rwoPv.spec.csi.volumeHandle
}
$ledger | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8

kubectl get pods,pvc -n $namespace -o wide
kubectl get pv $rwxPv.metadata.name $rwoPv.metadata.name -o wide
$modeOutput
Write-Host "Storage validation passed. Run scripts/cleanup-storage-validation.ps1 before considering the test complete."
