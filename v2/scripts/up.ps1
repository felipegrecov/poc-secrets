[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolsDir = Join-Path $projectRoot '.tools'
$clusterName = 'datenna-openbao'
$namespace = 'datenna-demo'
$openbaoNamespace = 'openbao'
$kindVersion = 'v0.32.0'
$kubectlVersion = 'v1.35.0'
$helmVersion = 'v3.21.0'
$cnpgVersion = '1.30.0'
$openbaoChartVersion = '0.29.1'
$csiDriverVersion = '1.6.0'

New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
& (Join-Path $PSScriptRoot 'generate-secrets.ps1')

function Assert-Succeeded([string] $Step) {
    if ($LASTEXITCODE -ne 0) { throw "$Step failed with exit code $LASTEXITCODE" }
}

function Invoke-NativeProbe([scriptblock] $Command) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Command 2>$null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{ Output = @($output); ExitCode = $exitCode }
}

function Resolve-OrDownloadTool(
    [string] $Name,
    [string] $LocalName,
    [string] $DownloadUrl,
    [string] $ChecksumUrl
) {
    $existing = Get-Command $Name -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }
    $localPath = Join-Path $toolsDir $LocalName
    if (-not (Test-Path -LiteralPath $localPath)) {
        Write-Host "Downloading $Name to .tools/"
        Invoke-WebRequest -UseBasicParsing -Uri $DownloadUrl -OutFile $localPath
    }
    $checksumContent = (Invoke-WebRequest -UseBasicParsing -Uri $ChecksumUrl).Content
    $checksumText = if ($checksumContent -is [byte[]]) {
        [Text.Encoding]::ASCII.GetString($checksumContent)
    } else { [string] $checksumContent }
    $expected = ($checksumText.Trim() -split '\s+')[0]
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $localPath).Hash
    if ($actual -ne $expected) { throw "SHA-256 verification failed for $Name" }
    return $localPath
}

function Resolve-OrDownloadHelm {
    $existing = Get-Command helm -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }
    $helmPath = Join-Path $toolsDir 'helm.exe'
    if (Test-Path -LiteralPath $helmPath) { return $helmPath }
    $archive = Join-Path $toolsDir "helm-$helmVersion-windows-amd64.zip"
    $url = "https://get.helm.sh/helm-$helmVersion-windows-amd64.zip"
    Write-Host 'Downloading helm to .tools/'
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
    $checksumContent = (Invoke-WebRequest -UseBasicParsing -Uri "$url.sha256sum").Content
    $checksumText = if ($checksumContent -is [byte[]]) {
        [Text.Encoding]::ASCII.GetString($checksumContent)
    } else { [string] $checksumContent }
    $expected = ($checksumText.Trim() -split '\s+')[0]
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash
    if ($actual -ne $expected) { throw 'SHA-256 verification failed for helm' }
    $extract = Join-Path $toolsDir "helm-$helmVersion"
    Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
    Move-Item -LiteralPath (Join-Path $extract 'windows-amd64\helm.exe') -Destination $helmPath
    Remove-Item -LiteralPath $archive
    Remove-Item -LiteralPath $extract -Recurse
    return $helmPath
}

function Wait-PodRunning([string] $Pod) {
    for ($attempt = 1; $attempt -le 90; $attempt++) {
        $probe = Invoke-NativeProbe { & $kubectl get pod $Pod --namespace $openbaoNamespace -o 'jsonpath={.status.phase}' }
        if ($probe.ExitCode -eq 0 -and ($probe.Output -join '') -eq 'Running') { return }
        Start-Sleep -Seconds 2
    }
    throw "Timed out waiting for $Pod to be Running"
}

function Invoke-Bao {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $InputData
    )
    if ($PSBoundParameters.ContainsKey('InputData')) {
        $result = $InputData | & $kubectl exec -i --namespace $openbaoNamespace openbao-0 -- env "BAO_TOKEN=$script:rootToken" bao @Arguments
    } else {
        $result = & $kubectl exec --namespace $openbaoNamespace openbao-0 -- env "BAO_TOKEN=$script:rootToken" bao @Arguments
    }
    Assert-Succeeded "OpenBao command: $($Arguments[0])"
    return $result
}

function Enable-BaoPath([string] $Kind, [string] $Path, [string[]] $EnableArguments) {
    $listingRaw = @(Invoke-Bao -Arguments @($Kind, 'list', '-format=json'))
    $listing = ($listingRaw -join "`n") | ConvertFrom-Json
    if ($listing.PSObject.Properties.Name -notcontains "$Path/") {
        Invoke-Bao -Arguments $EnableArguments | Out-Null
    }
}

$dockerCommand = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCommand) {
    $dockerDesktopBin = 'C:\Program Files\Docker\Docker\resources\bin'
    if (Test-Path -LiteralPath (Join-Path $dockerDesktopBin 'docker.exe')) {
        $env:PATH = "$dockerDesktopBin;$env:PATH"
        $dockerCommand = Get-Command docker
    }
}
if (-not $dockerCommand) { throw 'Docker was not found. Install Docker Desktop, start it, and rerun.' }

$kind = Resolve-OrDownloadTool -Name kind -LocalName kind.exe `
    -DownloadUrl "https://kind.sigs.k8s.io/dl/$kindVersion/kind-windows-amd64" `
    -ChecksumUrl "https://kind.sigs.k8s.io/dl/$kindVersion/kind-windows-amd64.sha256sum"
$kubectl = Resolve-OrDownloadTool -Name kubectl -LocalName kubectl.exe `
    -DownloadUrl "https://dl.k8s.io/release/$kubectlVersion/bin/windows/amd64/kubectl.exe" `
    -ChecksumUrl "https://dl.k8s.io/release/$kubectlVersion/bin/windows/amd64/kubectl.exe.sha256"
$helm = Resolve-OrDownloadHelm

& $dockerCommand.Source info *> $null
Assert-Succeeded 'Docker readiness check'

$secretsPath = Join-Path $projectRoot '.secrets.env'
$secrets = Get-Content -Raw -LiteralPath $secretsPath | ConvertFrom-StringData
$requiredSecretKeys = @(
    'MINIO_ROOT_USER', 'MINIO_ROOT_PASSWORD',
    'MINIO_BLUE_ACCESS_KEY', 'MINIO_BLUE_SECRET_KEY',
    'MINIO_GREEN_ACCESS_KEY', 'MINIO_GREEN_SECRET_KEY'
)
foreach ($key in $requiredSecretKeys) {
    if (-not $secrets[$key]) { throw "Missing $key in .secrets.env" }
}

$clusters = & $kind get clusters
Assert-Succeeded 'Listing kind clusters'
if ($clusters -notcontains $clusterName) {
    Write-Host 'Creating isolated kind cluster...'
    & $kind create cluster --name $clusterName --config (Join-Path $projectRoot 'infra\kind.yaml') --wait 5m
    Assert-Succeeded 'Creating kind cluster'
}

Write-Host 'Building and loading local images...'
& $dockerCommand.Source build --tag datenna-minio:2025-10-15 (Join-Path $projectRoot 'infra\minio')
Assert-Succeeded 'Building MinIO image'
& $dockerCommand.Source build --tag datenna-app:openbao $projectRoot
Assert-Succeeded 'Building application image'
& $kind load docker-image datenna-minio:2025-10-15 --name $clusterName
Assert-Succeeded 'Loading MinIO image'
& $kind load docker-image datenna-app:openbao --name $clusterName
Assert-Succeeded 'Loading application image'

Write-Host 'Installing CloudNativePG and the Secrets Store CSI driver...'
& $kubectl apply --server-side -f "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-$cnpgVersion.yaml"
Assert-Succeeded 'Installing CloudNativePG'
& $kubectl rollout status deployment/cnpg-controller-manager --namespace cnpg-system --timeout=5m
Assert-Succeeded 'Waiting for CloudNativePG'
& $helm upgrade --install secrets-store-csi-driver secrets-store-csi-driver `
    --repo https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts `
    --version $csiDriverVersion --namespace kube-system `
    --set-string 'tokenRequests[0].audience=openbao' --wait --timeout 5m
Assert-Succeeded 'Installing Secrets Store CSI driver'

& $kubectl apply -f (Join-Path $projectRoot 'k8s\namespace.yaml')
Assert-Succeeded 'Creating application namespace'
$minioRootSecret = & $kubectl create secret generic minio-root --namespace $namespace `
    --from-literal="username=$($secrets.MINIO_ROOT_USER)" `
    --from-literal="password=$($secrets.MINIO_ROOT_PASSWORD)" --dry-run=client -o yaml
$minioRootSecret | & $kubectl apply -f -
Assert-Succeeded 'Creating MinIO root Secret'
$minioState = & $kubectl get configmap minio-bootstrap-state --namespace $namespace --ignore-not-found -o name
Assert-Succeeded 'Checking MinIO bootstrap state'
$minioNeedsBootstrap = -not [bool] $minioState
if ($minioNeedsBootstrap) {
    $minioBootstrapSecret = & $kubectl create secret generic minio-app-bootstrap --namespace $namespace `
        --from-literal="blue-access-key=$($secrets.MINIO_BLUE_ACCESS_KEY)" `
        --from-literal="blue-secret-key=$($secrets.MINIO_BLUE_SECRET_KEY)" `
        --from-literal="green-access-key=$($secrets.MINIO_GREEN_ACCESS_KEY)" `
        --from-literal="green-secret-key=$($secrets.MINIO_GREEN_SECRET_KEY)" --dry-run=client -o yaml
    $minioBootstrapSecret | & $kubectl apply -f -
    Assert-Succeeded 'Creating temporary MinIO bootstrap Secret'
}

Write-Host 'Deploying PostgreSQL and MinIO...'
& $kubectl apply -f (Join-Path $projectRoot 'k8s\postgres.yaml')
Assert-Succeeded 'Creating PostgreSQL cluster'
& $kubectl apply -f (Join-Path $projectRoot 'k8s\minio.yaml')
Assert-Succeeded 'Deploying MinIO'
& $kubectl rollout status deployment/minio --namespace $namespace --timeout=5m
Assert-Succeeded 'Waiting for MinIO'
if ($minioNeedsBootstrap) {
    & $kubectl delete job minio-bootstrap --namespace $namespace --ignore-not-found
    Assert-Succeeded 'Resetting MinIO bootstrap Job'
    & $kubectl apply -f (Join-Path $projectRoot 'k8s\minio-bootstrap.yaml')
    Assert-Succeeded 'Creating MinIO bootstrap Job'
    & $kubectl wait --for=condition=complete job/minio-bootstrap --namespace $namespace --timeout=3m
    Assert-Succeeded 'Waiting for MinIO bootstrap'
    $state = & $kubectl create configmap minio-bootstrap-state --namespace $namespace --from-literal=complete=true --dry-run=client -o yaml
    $state | & $kubectl apply -f - | Out-Null
    Assert-Succeeded 'Recording MinIO bootstrap state'
    & $kubectl delete secret minio-app-bootstrap --namespace $namespace --ignore-not-found | Out-Null
}
& $kubectl wait --for=condition=Ready cluster/postgres --namespace $namespace --timeout=5m
Assert-Succeeded 'Waiting for PostgreSQL cluster'

Write-Host 'Installing OpenBao HA with integrated Raft storage...'
& $helm upgrade --install openbao openbao `
    --repo https://openbao.github.io/openbao-helm `
    --version $openbaoChartVersion --namespace $openbaoNamespace --create-namespace `
    -f (Join-Path $projectRoot 'k8s\openbao-values.yaml')
Assert-Succeeded 'Installing OpenBao chart'
foreach ($pod in @('openbao-0', 'openbao-1', 'openbao-2')) { Wait-PodRunning $pod }

$bootstrapPath = Join-Path $projectRoot '.openbao-bootstrap.json'
$statusProbe = Invoke-NativeProbe { & $kubectl exec --namespace $openbaoNamespace openbao-0 -- bao status -format=json }
$status = ($statusProbe.Output -join "`n") | ConvertFrom-Json
if (-not $status.initialized) {
    $initRaw = & $kubectl exec --namespace $openbaoNamespace openbao-0 -- bao operator init -format=json -key-shares=1 -key-threshold=1
    Assert-Succeeded 'Initializing OpenBao'
    $init = ($initRaw -join "`n") | ConvertFrom-Json
    $bootstrap = [ordered]@{ unseal_key = $init.unseal_keys_b64[0]; root_token = $init.root_token }
    [IO.File]::WriteAllText($bootstrapPath, ($bootstrap | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Write-Host 'Stored Git-ignored local OpenBao bootstrap material in .openbao-bootstrap.json.'
}
if (-not (Test-Path -LiteralPath $bootstrapPath)) {
    throw 'OpenBao is initialized but .openbao-bootstrap.json is missing; recovery keys are required.'
}
$bootstrap = Get-Content -Raw -LiteralPath $bootstrapPath | ConvertFrom-Json
$script:rootToken = $bootstrap.root_token
$unsealKey = $bootstrap.unseal_key

foreach ($pod in @('openbao-0', 'openbao-1', 'openbao-2')) {
    $podStatusProbe = Invoke-NativeProbe { & $kubectl exec --namespace $openbaoNamespace $pod -- bao status -format=json }
    $podStatus = ($podStatusProbe.Output -join "`n") | ConvertFrom-Json
    if (-not $podStatus.initialized -and $pod -ne 'openbao-0') {
        & $kubectl exec --namespace $openbaoNamespace $pod -- bao operator raft join http://openbao-0.openbao-internal:8200
        Assert-Succeeded "Joining $pod to Raft"
    }
    $podStatusProbe = Invoke-NativeProbe { & $kubectl exec --namespace $openbaoNamespace $pod -- bao status -format=json }
    $podStatus = ($podStatusProbe.Output -join "`n") | ConvertFrom-Json
    if ($podStatus.sealed) {
        & $kubectl exec --namespace $openbaoNamespace $pod -- bao operator unseal $unsealKey | Out-Null
        Assert-Succeeded "Unsealing $pod"
    }
}
& $kubectl wait --for=condition=Ready pod/openbao-0 pod/openbao-1 pod/openbao-2 --namespace $openbaoNamespace --timeout=5m
Assert-Succeeded 'Waiting for OpenBao HA'

Write-Host 'Configuring Kubernetes auth, PostgreSQL dynamic credentials, and MinIO KV...'
Enable-BaoPath -Kind secrets -Path database -EnableArguments @('secrets', 'enable', 'database')
Enable-BaoPath -Kind secrets -Path kv -EnableArguments @('secrets', 'enable', '-path=kv', 'kv-v2')
Enable-BaoPath -Kind auth -Path kubernetes -EnableArguments @('auth', 'enable', 'kubernetes')

$pgUserB64 = & $kubectl get secret postgres-superuser --namespace $namespace -o 'jsonpath={.data.username}'
Assert-Succeeded 'Reading generated PostgreSQL administrator username'
$pgPasswordB64 = & $kubectl get secret postgres-superuser --namespace $namespace -o 'jsonpath={.data.password}'
Assert-Succeeded 'Reading generated PostgreSQL administrator password'
$pgUser = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pgUserB64))
$pgPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pgPasswordB64))

$dbConfig = @{
    plugin_name = 'postgresql-database-plugin'
    allowed_roles = @('datenna-app')
    connection_url = 'postgresql://{{username}}:{{password}}@postgres-rw.datenna-demo.svc.cluster.local:5432/datenna?sslmode=require'
    username = $pgUser
    password = $pgPassword
} | ConvertTo-Json -Compress
Invoke-Bao -Arguments @('write', 'database/config/postgres', '-') -InputData $dbConfig | Out-Null
$dbRole = @{
    db_name = 'postgres'
    default_ttl = '2m'
    max_ttl = '10m'
    creation_statements = @('CREATE ROLE "{{name}}" WITH LOGIN PASSWORD ''{{password}}'' VALID UNTIL ''{{expiration}}''; GRANT datenna_runtime TO "{{name}}";')
    revocation_statements = @('REASSIGN OWNED BY "{{name}}" TO postgres; DROP OWNED BY "{{name}}"; DROP ROLE IF EXISTS "{{name}}";')
} | ConvertTo-Json -Compress
Invoke-Bao -Arguments @('write', 'database/roles/datenna-app', '-') -InputData $dbRole | Out-Null

$authConfig = @{ kubernetes_host = 'https://kubernetes.default.svc:443' } | ConvertTo-Json -Compress
Invoke-Bao -Arguments @('write', 'auth/kubernetes/config', '-') -InputData $authConfig | Out-Null
$authRole = @{
    bound_service_account_names = @('datenna-app')
    bound_service_account_namespaces = @($namespace)
    audience = 'openbao'
    token_policies = @('datenna-app')
    token_ttl = '10m'
} | ConvertTo-Json -Compress
Invoke-Bao -Arguments @('write', 'auth/kubernetes/role/datenna-app', '-') -InputData $authRole | Out-Null

$policy = @'
path "database/creds/datenna-app" {
  capabilities = ["read"]
}
path "kv/data/minio/datenna-app-active" {
  capabilities = ["read"]
}
'@
Invoke-Bao -Arguments @('policy', 'write', 'datenna-app', '-') -InputData $policy | Out-Null

function Write-MinioKv([string] $Path, [string] $Color, [string] $AccessKey, [string] $SecretKey) {
    $payload = @{ data = @{ color = $Color; 'access-key' = $AccessKey; 'secret-key' = $SecretKey } } | ConvertTo-Json -Compress
    Invoke-Bao -Arguments @('write', "kv/data/minio/$Path", '-') -InputData $payload | Out-Null
}
$minioKvProbe = Invoke-NativeProbe { & $kubectl exec --namespace $openbaoNamespace openbao-0 -- env "BAO_TOKEN=$script:rootToken" bao read -format=json kv/data/minio/datenna-app-active }
if ($minioKvProbe.ExitCode -ne 0) {
    Write-MinioKv -Path datenna-app-blue -Color blue -AccessKey $secrets.MINIO_BLUE_ACCESS_KEY -SecretKey $secrets.MINIO_BLUE_SECRET_KEY
    Write-MinioKv -Path datenna-app-green -Color green -AccessKey $secrets.MINIO_GREEN_ACCESS_KEY -SecretKey $secrets.MINIO_GREEN_SECRET_KEY
    Write-MinioKv -Path datenna-app-active -Color blue -AccessKey $secrets.MINIO_BLUE_ACCESS_KEY -SecretKey $secrets.MINIO_BLUE_SECRET_KEY
} else {
    Write-Host 'Preserving the existing MinIO blue/green KV state.'
}

Write-Host 'Deploying the application with CSI-mounted credentials...'
& $kubectl apply -f (Join-Path $projectRoot 'k8s\openbao-secret-provider.yaml')
Assert-Succeeded 'Creating SecretProviderClass'
& $kubectl apply -f (Join-Path $projectRoot 'k8s\app.yaml')
Assert-Succeeded 'Deploying FastAPI service'
& $kubectl set image deployment/datenna-app "api=datenna-app:openbao" --namespace $namespace
Assert-Succeeded 'Selecting OpenBao application image'
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

$demoBody = @{ content = "OpenBao end-to-end demo $(Get-Date -Format o)" } | ConvertTo-Json -Compress
$demo = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8080/demo' -ContentType application/json -Body $demoBody
if (-not $demo.verified) { throw 'The end-to-end demo returned verified=false' }
Write-Host "Ready: http://127.0.0.1:8080/docs (demo object $($demo.written.id))"
Write-Host 'PostgreSQL credentials are dynamic; MinIO uses the blue KV slot.'
