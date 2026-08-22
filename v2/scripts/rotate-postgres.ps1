[CmdletBinding()]
param([switch] $VerifyRevocation)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$kubectlCommand = Get-Command kubectl -ErrorAction SilentlyContinue
$kubectl = if ($kubectlCommand) { $kubectlCommand.Source } else { Join-Path $projectRoot '.tools\kubectl.exe' }
if (-not (Test-Path -LiteralPath $kubectl)) { throw 'kubectl was not found in PATH or .tools/' }

function Current-AppPod {
    & $kubectl get pods -n datenna-demo -l app.kubernetes.io/name=datenna-app -o 'jsonpath={.items[0].metadata.name}'
    if ($LASTEXITCODE -ne 0) { throw 'Could not find the application pod' }
}

$oldPod = Current-AppPod
$oldUser = & $kubectl exec -n datenna-demo $oldPod -- cat /var/run/secrets/datenna/postgres-username
if ($LASTEXITCODE -ne 0) { throw 'Could not read the current dynamic username' }

& $kubectl rollout restart deployment/datenna-app -n datenna-demo
if ($LASTEXITCODE -ne 0) { throw 'Could not start the rollout' }
& $kubectl rollout status deployment/datenna-app -n datenna-demo --timeout=5m
if ($LASTEXITCODE -ne 0) { throw 'The new application pod did not become ready' }

$newPod = Current-AppPod
$newUser = & $kubectl exec -n datenna-demo $newPod -- cat /var/run/secrets/datenna/postgres-username
if ($LASTEXITCODE -ne 0) { throw 'Could not read the new dynamic username' }
if ($newUser -eq $oldUser) { throw 'OpenBao returned the same PostgreSQL identity after rollout' }

Write-Host "PostgreSQL identity rotated: $oldUser -> $newUser"
Write-Host 'The old identity remains valid only until its OpenBao lease is revoked or expires.'

if ($VerifyRevocation) {
    Write-Host 'Waiting 150 seconds (the configured default lease is 2 minutes)...'
    Start-Sleep -Seconds 150
    $exists = & $kubectl exec -n datenna-demo postgres-1 -- psql -d datenna -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$oldUser'"
    if ($LASTEXITCODE -ne 0) { throw 'Could not query PostgreSQL roles' }
    if ($exists.Trim() -eq '1') { throw "Old PostgreSQL role still exists: $oldUser" }
    Write-Host 'Verified: the expired PostgreSQL role was revoked and dropped.'
}
