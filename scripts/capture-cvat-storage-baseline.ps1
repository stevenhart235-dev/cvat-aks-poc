[CmdletBinding()]
param(
    [string]$ClusterResourceGroup = 'rg-cvat-poc', [string]$ClusterName = 'aks-cvat-poc',
    [string]$Namespace = 'cvat', [string]$ReleaseName = 'cvat', [string]$BaselinePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BaselinePath)) { $BaselinePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/cvat-storage-baseline.json' }
if (Test-Path -LiteralPath $BaselinePath) { throw "Baseline already exists at $BaselinePath. Refusing to overwrite it." }
$account = az account show -o json | ConvertFrom-Json
$cluster = az aks show -g $ClusterResourceGroup -n $ClusterName -o json | ConvertFrom-Json -Depth 100
$context = kubectl config current-context
if ($LASTEXITCODE -ne 0 -or $account.state -ne 'Enabled' -or $cluster.provisioningState -ne 'Succeeded' -or $context -ne $ClusterName) { throw 'Azure and kubectl contexts must identify the ready expected cluster.' }
$release = helm list -n $Namespace --filter "^$ReleaseName$" -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or @($release).Count -ne 0) { throw 'Capture the storage baseline before the CVAT Helm release exists.' }
$accounts = @(az storage account list -g $cluster.nodeResourceGroup -o json | ConvertFrom-Json -Depth 100 | ForEach-Object id)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inventory baseline storage accounts.' }
$baseline = [ordered]@{schemaVersion=1;capturedAtUtc=(Get-Date).ToUniversalTime().ToString('o');subscriptionId=$account.id;clusterResourceGroup=$ClusterResourceGroup;clusterName=$ClusterName;nodeResourceGroup=$cluster.nodeResourceGroup;namespace=$Namespace;releaseName=$ReleaseName;storageAccountIds=$accounts}
$directory = Split-Path -Parent $BaselinePath; if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$baseline | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $BaselinePath -Encoding utf8
Write-Host "Captured the pre-deployment storage-account baseline at $BaselinePath"
