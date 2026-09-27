$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$generator = Join-Path $repoRoot 'scripts\New-CvatM4bSecrets.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cvat-secret-test-" + [guid]::NewGuid().ToString('N'))
$outputPath = Join-Path $tempRoot 'values-m4b-secrets.local.yaml'

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $captured = @(& $generator -OutputPath $outputPath *>&1)
    if ($captured.Count -ne 0) {
        throw 'Secret generator emitted output.'
    }
    if (-not (Test-Path -LiteralPath $outputPath)) {
        throw 'Secret generator did not create the requested file.'
    }

    $content = Get-Content -Raw -LiteralPath $outputPath
    if ($content -match 'REPLACE_WITH_') {
        throw 'Generated overlay still contains a placeholder.'
    }
    $matches = [regex]::Matches(
        $content,
        '(?m)^\s+(?:password|postgres_password|replication_password|clickhousePassword|adminPassword|django-secret-key):\s*(\S+)\s*$'
    )
    $values = @($matches | ForEach-Object { $_.Groups[1].Value })
    if ($values.Count -ne 8) {
        throw 'Generated overlay does not contain exactly eight sensitive values.'
    }
    if (@($values | Select-Object -Unique).Count -ne 8) {
        throw 'Generated secret values are not unique.'
    }
    if (@($values | Where-Object { $_ -notmatch '^[A-Za-z0-9_-]{43}$' }).Count -ne 0) {
        throw 'Generated values do not each contain 256 bits of encoded random material.'
    }

    $refused = $false
    try {
        & $generator -OutputPath $outputPath *> $null
    } catch {
        $refused = $true
    }
    if (-not $refused) {
        throw 'Secret generator did not refuse to overwrite an existing overlay.'
    }

    Write-Output 'PASS: secret generator is silent, non-overwriting, and creates eight unique 256-bit values'
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}