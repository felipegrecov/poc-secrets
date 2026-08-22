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

& $kind delete cluster --name datenna-openbao
if ($LASTEXITCODE -ne 0) {
    throw "Deleting kind cluster failed with exit code $LASTEXITCODE"
}

if ($PurgeSecrets) {
    foreach ($name in @('.secrets.env', '.openbao-bootstrap.json')) {
        $secretPath = Join-Path $projectRoot $name
        if (Test-Path -LiteralPath $secretPath) {
            Remove-Item -LiteralPath $secretPath
            Write-Host "Deleted $name; it cannot be recovered from this project."
        }
    }
}
