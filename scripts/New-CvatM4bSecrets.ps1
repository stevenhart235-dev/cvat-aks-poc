[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\helm\cvat\values-m4b-secrets.local.yaml')
)

$ErrorActionPreference = 'Stop'
$examplePath = Join-Path $PSScriptRoot '..\helm\cvat\values-m4b-secrets.example.yaml'
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)

if (Test-Path -LiteralPath $resolvedOutput) {
    throw "Refusing to overwrite existing local secret overlay: $resolvedOutput"
}

function New-CryptographicValue {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$placeholders = @(
    'REPLACE_WITH_RANDOM_CVAT_DATABASE_PASSWORD',
    'REPLACE_WITH_RANDOM_POSTGRES_ADMIN_PASSWORD',
    'REPLACE_WITH_RANDOM_POSTGRES_REPLICATION_PASSWORD',
    'REPLACE_WITH_RANDOM_REDIS_PASSWORD',
    'REPLACE_WITH_RANDOM_KVROCKS_PASSWORD',
    'REPLACE_WITH_RANDOM_CLICKHOUSE_PASSWORD',
    'REPLACE_WITH_RANDOM_GRAFANA_ADMIN_PASSWORD',
    'REPLACE_WITH_RANDOM_DJANGO_SECRET_KEY'
)

$content = Get-Content -Raw -LiteralPath $examplePath
$generated = [System.Collections.Generic.HashSet[string]]::new()
foreach ($placeholder in $placeholders) {
    do {
        $value = New-CryptographicValue
    } until ($generated.Add($value))
    $content = $content.Replace($placeholder, $value)
}

if ($content -match 'REPLACE_WITH_') {
    throw 'The example contains an unhandled secret placeholder.'
}

$parent = Split-Path -Parent $resolvedOutput
if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent | Out-Null
}
[System.IO.File]::WriteAllText($resolvedOutput, $content, [System.Text.UTF8Encoding]::new($false))