[CmdletBinding()]
param(
    [switch] $PurgeSecrets
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$localKind = Join-Path $projectRoot '.tools\kind.exe'
$kindCommand = Get-Command kind -ErrorAction SilentlyContinue
$kind = if ($kindCommand) { $kindCommand.Source } elseif (Test-Path $localKind) { $localKind } else { $null }

if (-not $kind) {
    throw 'kind was not found in PATH or .tools/'
}

& $kind delete cluster --name datenna-exercise
if ($LASTEXITCODE -ne 0) {
    throw "Deleting kind cluster failed with exit code $LASTEXITCODE"
}

if ($PurgeSecrets) {
    $secretsPath = Join-Path $projectRoot '.secrets.env'
    if (Test-Path -LiteralPath $secretsPath) {
        Remove-Item -LiteralPath $secretsPath
        Write-Host 'Deleted .secrets.env; it cannot be recovered from this project.'
    }
}

