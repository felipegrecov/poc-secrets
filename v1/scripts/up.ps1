[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolsDir = Join-Path $projectRoot '.tools'
$clusterName = 'datenna-exercise'
$namespace = 'datenna-demo'
$kindVersion = 'v0.32.0'
$kubectlVersion = 'v1.35.0'
$cnpgVersion = '1.30.0'

New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
& (Join-Path $PSScriptRoot 'generate-secrets.ps1')

function Assert-Succeeded([string] $Step) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

function Resolve-OrDownloadTool(
    [string] $Name,
    [string] $LocalName,
    [string] $DownloadUrl,
    [string] $ChecksumUrl
) {
    $existing = Get-Command $Name -ErrorAction SilentlyContinue
    if ($existing) {
        return $existing.Source
    }

    $localPath = Join-Path $toolsDir $LocalName
    if (-not (Test-Path -LiteralPath $localPath)) {
        Write-Host "Downloading $Name to .tools/"
        Invoke-WebRequest -UseBasicParsing -Uri $DownloadUrl -OutFile $localPath
    }
    $checksumContent = (Invoke-WebRequest -UseBasicParsing -Uri $ChecksumUrl).Content
    $checksumText = if ($checksumContent -is [byte[]]) {
        [Text.Encoding]::ASCII.GetString($checksumContent)
    } else {
        [string] $checksumContent
    }
    $expected = ($checksumText.Trim() -split '\s+')[0]
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $localPath).Hash
    if ($actual -ne $expected) {
        throw "SHA-256 verification failed for $Name"
    }
    return $localPath
}

$dockerCommand = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCommand) {
    $dockerDesktopBin = 'C:\Program Files\Docker\Docker\resources\bin'
    $dockerDesktop = Join-Path $dockerDesktopBin 'docker.exe'
    if (Test-Path -LiteralPath $dockerDesktop) {
        $env:PATH = "$dockerDesktopBin;$env:PATH"
        $dockerCommand = Get-Command docker
    }
}
if (-not $dockerCommand) {
    throw 'Docker was not found. Install Docker Desktop, start it, and rerun this script.'
}

$kind = Resolve-OrDownloadTool `
    -Name 'kind' `
    -LocalName 'kind.exe' `
    -DownloadUrl "https://kind.sigs.k8s.io/dl/$kindVersion/kind-windows-amd64" `
    -ChecksumUrl "https://kind.sigs.k8s.io/dl/$kindVersion/kind-windows-amd64.sha256sum"
$kubectl = Resolve-OrDownloadTool `
    -Name 'kubectl' `
    -LocalName 'kubectl.exe' `
    -DownloadUrl "https://dl.k8s.io/release/$kubectlVersion/bin/windows/amd64/kubectl.exe" `
    -ChecksumUrl "https://dl.k8s.io/release/$kubectlVersion/bin/windows/amd64/kubectl.exe.sha256"

& $dockerCommand.Source info *> $null
Assert-Succeeded 'Docker readiness check'

$secretsPath = Join-Path $projectRoot '.secrets.env'
if (-not (Test-Path -LiteralPath $secretsPath)) {
    throw '.secrets.env generation failed'
}

$secrets = Get-Content -Raw -LiteralPath $secretsPath | ConvertFrom-StringData
$requiredSecretKeys = @(
    'POSTGRES_USER',
    'POSTGRES_PASSWORD',
    'MINIO_ROOT_USER',
    'MINIO_ROOT_PASSWORD',
    'MINIO_APP_ACCESS_KEY',
    'MINIO_APP_SECRET_KEY'
)
foreach ($key in $requiredSecretKeys) {
    if (-not $secrets[$key]) {
        throw "Missing $key in .secrets.env"
    }
}

$clusters = & $kind get clusters
Assert-Succeeded 'Listing kind clusters'
if ($clusters -notcontains $clusterName) {
    Write-Host 'Creating kind cluster...'
    & $kind create cluster --name $clusterName --config (Join-Path $projectRoot 'infra\kind.yaml') --wait 5m
    Assert-Succeeded 'Creating kind cluster'
}

Write-Host 'Building local images...'
& $dockerCommand.Source build --tag datenna-minio:2025-10-15 (Join-Path $projectRoot 'infra\minio')
Assert-Succeeded 'Building MinIO image'
& $dockerCommand.Source build --tag datenna-app:local $projectRoot
Assert-Succeeded 'Building application image'

& $kind load docker-image datenna-minio:2025-10-15 --name $clusterName
Assert-Succeeded 'Loading MinIO image into kind'
& $kind load docker-image datenna-app:local --name $clusterName
Assert-Succeeded 'Loading application image into kind'

Write-Host 'Installing CloudNativePG...'
& $kubectl apply --server-side -f "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-$cnpgVersion.yaml"
Assert-Succeeded 'Installing CloudNativePG'
& $kubectl rollout status deployment/cnpg-controller-manager --namespace cnpg-system --timeout=5m
Assert-Succeeded 'Waiting for CloudNativePG'

& $kubectl apply -f (Join-Path $projectRoot 'k8s\namespace.yaml')
Assert-Succeeded 'Creating application namespace'

$postgresSecret = & $kubectl create secret generic postgres-app `
    --namespace $namespace `
    --type kubernetes.io/basic-auth `
    --from-literal="username=$($secrets.POSTGRES_USER)" `
    --from-literal="password=$($secrets.POSTGRES_PASSWORD)" `
    --dry-run=client -o yaml
$postgresSecret | & $kubectl apply -f -
Assert-Succeeded 'Creating PostgreSQL Secret'

$minioRootSecret = & $kubectl create secret generic minio-root `
    --namespace $namespace `
    --from-literal="username=$($secrets.MINIO_ROOT_USER)" `
    --from-literal="password=$($secrets.MINIO_ROOT_PASSWORD)" `
    --dry-run=client -o yaml
$minioRootSecret | & $kubectl apply -f -
Assert-Succeeded 'Creating MinIO root Secret'

$minioAppSecret = & $kubectl create secret generic minio-app `
    --namespace $namespace `
    --from-literal="access-key=$($secrets.MINIO_APP_ACCESS_KEY)" `
    --from-literal="secret-key=$($secrets.MINIO_APP_SECRET_KEY)" `
    --dry-run=client -o yaml
$minioAppSecret | & $kubectl apply -f -
Assert-Succeeded 'Creating MinIO application Secret'

Write-Host 'Deploying PostgreSQL and MinIO...'
& $kubectl apply -f (Join-Path $projectRoot 'k8s\postgres.yaml')
Assert-Succeeded 'Creating PostgreSQL cluster'
& $kubectl apply -f (Join-Path $projectRoot 'k8s\minio.yaml')
Assert-Succeeded 'Deploying MinIO'
& $kubectl rollout status deployment/minio --namespace $namespace --timeout=5m
Assert-Succeeded 'Waiting for MinIO'

& $kubectl delete job minio-bootstrap --namespace $namespace --ignore-not-found
Assert-Succeeded 'Resetting MinIO bootstrap Job'
& $kubectl apply -f (Join-Path $projectRoot 'k8s\minio-bootstrap.yaml')
Assert-Succeeded 'Creating MinIO bootstrap Job'
& $kubectl wait --for=condition=complete job/minio-bootstrap --namespace $namespace --timeout=3m
Assert-Succeeded 'Waiting for MinIO bootstrap'

& $kubectl wait --for=condition=Ready cluster/postgres --namespace $namespace --timeout=5m
Assert-Succeeded 'Waiting for PostgreSQL cluster'

Write-Host 'Deploying FastAPI service...'
& $kubectl apply -f (Join-Path $projectRoot 'k8s\app.yaml')
Assert-Succeeded 'Deploying FastAPI service'
& $kubectl rollout status deployment/datenna-app --namespace $namespace --timeout=5m
Assert-Succeeded 'Waiting for FastAPI service'

for ($attempt = 1; $attempt -le 30; $attempt++) {
    try {
        $ready = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/readyz' -TimeoutSec 2
        if ($ready.status -eq 'ready') { break }
    } catch {
        if ($attempt -eq 30) { throw 'FastAPI did not become reachable on http://127.0.0.1:8080' }
        Start-Sleep -Seconds 2
    }
}

$demoBody = @{ content = "end-to-end demo $(Get-Date -Format o)" } | ConvertTo-Json -Compress
$demo = Invoke-RestMethod `
    -Method Post `
    -Uri 'http://127.0.0.1:8080/demo' `
    -ContentType 'application/json' `
    -Body $demoBody

if (-not $demo.verified) {
    throw 'The end-to-end demo returned verified=false'
}
Write-Host "Ready: http://127.0.0.1:8080/docs (demo object $($demo.written.id))"
