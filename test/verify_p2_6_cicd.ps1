Param(
  [string]$EnvFile = '.env.dev.ha.mqtt.dbha',
  [string]$GatewayBase = 'https://127.0.0.1'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $EnvFile)) {
  throw "Env file not found: $EnvFile"
}

$envMap = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
  $parts = $_.Split('=', 2)
  $envMap[$parts[0].Trim()] = $parts[1]
}

$apiKey = $envMap['API_KEY']
if (-not $apiKey) {
  throw "API_KEY missing in $EnvFile"
}

function Get-HeaderValue {
  param(
    [string[]]$HeaderLines,
    [string]$Name
  )

  $line = $HeaderLines | Select-String -Pattern ('^' + [regex]::Escape($Name) + ':') -CaseSensitive:$false | Select-Object -Last 1
  if ($null -eq $line) { return '' }
  return (($line.Line -replace '^[^:]+:\s*', '').Trim())
}

function Get-StatusCodeFromHeaders {
  param([string[]]$HeaderLines)
  $statusLine = ($HeaderLines | Select-String -Pattern '^HTTP/' | Select-Object -Last 1).Line
  if (-not $statusLine) { return 0 }
  $parts = $statusLine -split '\s+'
  if ($parts.Count -lt 2) { return 0 }
  return [int]$parts[1]
}

function Wait-HealthVersion {
  param(
    [string]$Url,
    [string]$ExpectedVersion,
    [string]$ExpectedChannel,
    [int]$TimeoutSec = 60
  )

  $start = Get-Date
  while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSec) {
    try {
      $h = Invoke-RestMethod $Url -Method Get
      if ($h.release_version -eq $ExpectedVersion -and $h.release_channel -eq $ExpectedChannel) {
        return $h
      }
    } catch {
    }
    Start-Sleep -Seconds 2
  }

  throw "Health version wait timed out: $Url => version=$ExpectedVersion channel=$ExpectedChannel"
}

function Invoke-GatewayHeaders {
  param(
    [string]$Url,
    [string[]]$ExtraHeaders = @()
  )

  $args = @('-k', '-s', '-D', '-', '-o', 'NUL')
  foreach ($header in $ExtraHeaders) {
    $args += @('-H', $header)
  }
  $args += $Url

  $headers = & curl.exe @args
  if ($LASTEXITCODE -ne 0) {
    throw "curl failed: $Url"
  }
  return $headers
}

Write-Host '[1/8] Check workflow and CI script files'
$requiredFiles = @(
  '.github/workflows/p2_6_ci.yml',
  'scripts/run_ci_local.ps1',
  'scripts/deploy_canary_release.ps1',
  'scripts/promote_canary_release.ps1',
  'scripts/rollback_canary_release.ps1'
)
foreach ($f in $requiredFiles) {
  if (-not (Test-Path $f)) {
    throw "required file missing: $f"
  }
}
Write-Host '  workflow and scripts exist'

Write-Host '[2/8] Run local CI baseline'
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_ci_local.ps1
if ($LASTEXITCODE -ne 0) {
  throw 'run_ci_local.ps1 failed'
}
Write-Host '  local ci ok'

Write-Host '[3/8] Capture baseline release versions'
$api1Before = Invoke-RestMethod 'http://127.0.0.1:18001/health' -Method Get
$api2Before = Invoke-RestMethod 'http://127.0.0.1:18002/health' -Method Get
if ($api1Before.release_channel -ne 'stable') { throw 'backend_api_1 should be stable channel' }
if ($api2Before.release_channel -ne 'canary') { throw 'backend_api_2 should be canary channel' }
$stableBefore = [string]$api1Before.release_version
if (-not $stableBefore) { throw 'stable release version missing before deploy' }
$canaryVersion = 'p26-canary-' + (Get-Date -Format 'yyyyMMdd_HHmmss')
Write-Host "  stable before=$stableBefore, canary before=$($api2Before.release_version)"

Write-Host '[4/8] Deploy canary release'
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\deploy_canary_release.ps1 -EnvFile $EnvFile -CanaryVersion $canaryVersion
if ($LASTEXITCODE -ne 0) {
  throw 'deploy_canary_release.ps1 failed'
}
$api2AfterDeploy = Wait-HealthVersion -Url 'http://127.0.0.1:18002/health' -ExpectedVersion $canaryVersion -ExpectedChannel 'canary'
Write-Host "  canary deployed => $($api2AfterDeploy.release_version)"

Write-Host '[5/8] Verify gateway gray routing'
$defaultHeaders = Invoke-GatewayHeaders -Url "$GatewayBase/api/device_status" -ExtraHeaders @("Authorization: Bearer $apiKey")
$defaultCode = Get-StatusCodeFromHeaders -HeaderLines $defaultHeaders
if ($defaultCode -ne 200) { throw "stable gateway request expected 200, got $defaultCode" }
$defaultInst = Get-HeaderValue -HeaderLines $defaultHeaders -Name 'X-Backend-Instance'
$defaultVersion = Get-HeaderValue -HeaderLines $defaultHeaders -Name 'X-Release-Version'
$defaultChannel = Get-HeaderValue -HeaderLines $defaultHeaders -Name 'X-Release-Channel'
if ($defaultInst -ne 'backend-api-1') { throw "stable gateway should hit backend-api-1, got $defaultInst" }
if ($defaultVersion -ne $stableBefore) { throw "stable gateway version mismatch: $defaultVersion" }
if ($defaultChannel -ne 'stable') { throw "stable gateway channel mismatch: $defaultChannel" }

$canaryHeaders = Invoke-GatewayHeaders -Url "$GatewayBase/api/device_status" -ExtraHeaders @("Authorization: Bearer $apiKey", 'X-Release-Channel: canary')
$canaryCode = Get-StatusCodeFromHeaders -HeaderLines $canaryHeaders
if ($canaryCode -ne 200) { throw "canary gateway request expected 200, got $canaryCode" }
$canaryInst = Get-HeaderValue -HeaderLines $canaryHeaders -Name 'X-Backend-Instance'
$canaryVersionHeader = Get-HeaderValue -HeaderLines $canaryHeaders -Name 'X-Release-Version'
$canaryChannelHeader = Get-HeaderValue -HeaderLines $canaryHeaders -Name 'X-Release-Channel'
if ($canaryInst -ne 'backend-api-2') { throw "canary gateway should hit backend-api-2, got $canaryInst" }
if ($canaryVersionHeader -ne $canaryVersion) { throw "canary gateway version mismatch: $canaryVersionHeader" }
if ($canaryChannelHeader -ne 'canary') { throw "canary gateway channel mismatch: $canaryChannelHeader" }
Write-Host '  gateway gray routing ok'

Write-Host '[6/8] Promote canary release'
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\promote_canary_release.ps1 -EnvFile $EnvFile
if ($LASTEXITCODE -ne 0) {
  throw 'promote_canary_release.ps1 failed'
}
$api1AfterPromote = Wait-HealthVersion -Url 'http://127.0.0.1:18001/health' -ExpectedVersion $canaryVersion -ExpectedChannel 'stable'
$defaultAfterPromote = Invoke-GatewayHeaders -Url "$GatewayBase/api/device_status" -ExtraHeaders @("Authorization: Bearer $apiKey")
if ((Get-HeaderValue -HeaderLines $defaultAfterPromote -Name 'X-Release-Version') -ne $canaryVersion) {
  throw 'stable gateway did not switch to promoted version'
}
Write-Host "  promoted stable => $($api1AfterPromote.release_version)"

Write-Host '[7/8] Rollback to previous stable release'
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rollback_canary_release.ps1 -EnvFile $EnvFile -RollbackVersion $stableBefore
if ($LASTEXITCODE -ne 0) {
  throw 'rollback_canary_release.ps1 failed'
}
$api1AfterRollback = Wait-HealthVersion -Url 'http://127.0.0.1:18001/health' -ExpectedVersion $stableBefore -ExpectedChannel 'stable'
$api2AfterRollback = Wait-HealthVersion -Url 'http://127.0.0.1:18002/health' -ExpectedVersion $stableBefore -ExpectedChannel 'canary'
$defaultAfterRollback = Invoke-GatewayHeaders -Url "$GatewayBase/api/device_status" -ExtraHeaders @("Authorization: Bearer $apiKey")
if ((Get-HeaderValue -HeaderLines $defaultAfterRollback -Name 'X-Release-Version') -ne $stableBefore) {
  throw 'stable gateway did not rollback to previous version'
}
Write-Host "  rollback ok => stable=$($api1AfterRollback.release_version), canary=$($api2AfterRollback.release_version)"

Write-Host '[8/8] PASS: P2-6 CI/CD and gray release baseline works'
