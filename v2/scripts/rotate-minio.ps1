[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$kubectlCommand = Get-Command kubectl -ErrorAction SilentlyContinue
$kubectl = if ($kubectlCommand) { $kubectlCommand.Source } else { Join-Path $projectRoot '.tools\kubectl.exe' }
if (-not (Test-Path -LiteralPath $kubectl)) { throw 'kubectl was not found in PATH or .tools/' }
$bootstrapPath = Join-Path $projectRoot '.openbao-bootstrap.json'
if (-not (Test-Path -LiteralPath $bootstrapPath)) { throw '.openbao-bootstrap.json is required' }
$rootToken = (Get-Content -Raw -LiteralPath $bootstrapPath | ConvertFrom-Json).root_token

function New-HexSecret([int] $ByteCount) {
    [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes($ByteCount)).ToLowerInvariant()
}

function Invoke-Bao([string[]] $Arguments, [string] $InputData) {
    if ($PSBoundParameters.ContainsKey('InputData')) {
        $result = $InputData | & $kubectl exec -i -n openbao openbao-0 -- env "BAO_TOKEN=$rootToken" bao @Arguments
    } else {
        $result = & $kubectl exec -n openbao openbao-0 -- env "BAO_TOKEN=$rootToken" bao @Arguments
    }
    if ($LASTEXITCODE -ne 0) { throw "OpenBao command failed: $($Arguments[0])" }
    return $result
}

function Write-ActiveKv($Credentials) {
    $payload = @{ data = @{ color = $Credentials.color; 'access-key' = $Credentials.'access-key'; 'secret-key' = $Credentials.'secret-key' } } | ConvertTo-Json -Compress
    Invoke-Bao @('write', 'kv/data/minio/datenna-app-active', '-') $payload | Out-Null
}

function Invoke-MinioOperation([string] $Action, [string] $AccessKey, [string] $SecretKey) {
    & $kubectl delete job minio-user-operation -n datenna-demo --ignore-not-found | Out-Null
    $secretYaml = & $kubectl create secret generic minio-user-operation -n datenna-demo `
        --from-literal="action=$Action" --from-literal="access-key=$AccessKey" `
        --from-literal="secret-key=$SecretKey" --dry-run=client -o yaml
    $secretYaml | & $kubectl apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the temporary MinIO operation Secret' }
    & $kubectl apply -f (Join-Path $projectRoot 'k8s\minio-user-operation.yaml') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the MinIO operation Job' }
    & $kubectl wait --for=condition=complete job/minio-user-operation -n datenna-demo --timeout=3m | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "MinIO $Action operation failed" }
}

$activeRaw = Invoke-Bao @('read', '-format=json', 'kv/data/minio/datenna-app-active')
$old = (($activeRaw -join "`n") | ConvertFrom-Json).data.data
$newColor = if ($old.color -eq 'blue') { 'green' } else { 'blue' }
$new = [pscustomobject]@{
    color = $newColor
    'access-key' = "app-$newColor-$(New-HexSecret 8)"
    'secret-key' = New-HexSecret 24
}
$inactiveRaw = Invoke-Bao @('read', '-format=json', "kv/data/minio/datenna-app-$newColor")
$inactive = (($inactiveRaw -join "`n") | ConvertFrom-Json).data.data
$switched = $false

try {
    Invoke-MinioOperation remove $inactive.'access-key' 'unused'
    Invoke-MinioOperation create $new.'access-key' $new.'secret-key'
    $slotPayload = @{ data = @{ color = $new.color; 'access-key' = $new.'access-key'; 'secret-key' = $new.'secret-key' } } | ConvertTo-Json -Compress
    Invoke-Bao @('write', "kv/data/minio/datenna-app-$newColor", '-') $slotPayload | Out-Null
    Write-ActiveKv $new
    $switched = $true

    & $kubectl rollout restart deployment/datenna-app -n datenna-demo | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restart the application' }
    & $kubectl rollout status deployment/datenna-app -n datenna-demo --timeout=5m | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The application did not become ready with the new MinIO credentials' }
    $demoVerified = $false
    for ($attempt = 1; $attempt -le 15; $attempt++) {
        try {
            $demo = Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/demo -ContentType application/json -Body '{"content":"MinIO blue-green rotation verification"}'
            if ($demo.verified) {
                $demoVerified = $true
                break
            }
        } catch {
            if ($attempt -eq 15) { throw }
        }
        Start-Sleep -Seconds 2
    }
    if (-not $demoVerified) { throw 'The post-rotation demo failed' }

    Invoke-MinioOperation disable $old.'access-key' 'unused'
    Write-Host "MinIO switched $($old.color) -> $newColor; the old user is disabled."
} catch {
    if ($switched) {
        Write-Warning 'Rotation failed after the KV switch; restoring the previous active slot.'
        Write-ActiveKv $old
        & $kubectl rollout restart deployment/datenna-app -n datenna-demo | Out-Null
        & $kubectl rollout status deployment/datenna-app -n datenna-demo --timeout=5m | Out-Null
    }
    try { Invoke-MinioOperation disable $new.'access-key' 'unused' } catch { Write-Warning 'Could not disable the failed new MinIO user.' }
    throw
} finally {
    & $kubectl delete secret minio-user-operation -n datenna-demo --ignore-not-found | Out-Null
}
