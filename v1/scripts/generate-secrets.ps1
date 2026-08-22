[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$secretsPath = Join-Path $projectRoot '.secrets.env'

if (Test-Path -LiteralPath $secretsPath) {
    Write-Host '.secrets.env already exists; leaving it unchanged.'
    exit 0
}

function New-HexSecret([int] $ByteCount) {
    $bytes = New-Object byte[] $ByteCount
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    } finally {
        $generator.Dispose()
    }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

$secretLines = @(
    'POSTGRES_USER=datenna_app'
    "POSTGRES_PASSWORD=$(New-HexSecret 24)"
    "MINIO_ROOT_USER=root-$(New-HexSecret 8)"
    "MINIO_ROOT_PASSWORD=$(New-HexSecret 24)"
    "MINIO_APP_ACCESS_KEY=app-$(New-HexSecret 8)"
    "MINIO_APP_SECRET_KEY=$(New-HexSecret 24)"
)
[IO.File]::WriteAllLines($secretsPath, $secretLines, [Text.UTF8Encoding]::new($false))
Write-Host 'Generated .secrets.env (Git-ignored; values are not printed).'
