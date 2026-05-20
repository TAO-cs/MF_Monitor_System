Param(
  [string]$EnvFile = ".env.dev.ha",
  [string]$GatewayBase = "https://127.0.0.1"
)

$ErrorActionPreference = "Stop"

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

  $line = $HeaderLines | Select-String -Pattern ("^" + [regex]::Escape($Name) + ":") -CaseSensitive:$false | Select-Object -Last 1
  if ($null -eq $line) { return "" }
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

function Get-MetricValue {
  param([string]$Metrics, [string]$MetricName)

  $pattern = '(?m)^' + [regex]::Escape($MetricName) + '\s+([0-9.]+)$'
  $m = [regex]::Match($Metrics, $pattern)
  if (-not $m.Success) { return $null }
  return [double]$m.Groups[1].Value
}

Write-Host "[1/7] Check required containers"
$required = @('mf_mysql','mf_mqtt','mf_nginx','mf_backend_api_1','mf_backend_api_2','mf_backend_worker')
foreach ($c in $required) {
  $running = (docker inspect -f '{{.State.Running}}' $c 2>$null)
  if ($LASTEXITCODE -ne 0 -or $running.Trim() -ne 'true') {
    throw "container not running: $c"
  }
}
Write-Host "  containers ok"

Write-Host "[2/7] Check direct backend health"
$api1 = Invoke-RestMethod "http://127.0.0.1:18001/health" -Method Get
$api2 = Invoke-RestMethod "http://127.0.0.1:18002/health" -Method Get
$worker = Invoke-RestMethod "http://127.0.0.1:18003/health" -Method Get

if ($api1.instance_id -ne 'backend-api-1' -or [bool]$api1.ingestion_enabled) {
  throw "backend_api_1 health mismatch: $($api1 | ConvertTo-Json -Compress)"
}
if ($api2.instance_id -ne 'backend-api-2' -or [bool]$api2.ingestion_enabled) {
  throw "backend_api_2 health mismatch: $($api2 | ConvertTo-Json -Compress)"
}
if ($worker.instance_id -ne 'backend-worker' -or -not [bool]$worker.ingestion_enabled) {
  throw "backend_worker health mismatch: $($worker | ConvertTo-Json -Compress)"
}
Write-Host "  direct health ok"

Write-Host "[3/7] Check gateway routing and instance header"
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
for ($i = 0; $i -lt 12; $i++) {
  $headers = & curl.exe -k -s -D - -o NUL "$GatewayBase/health"
  $status = Get-StatusCodeFromHeaders -HeaderLines $headers
  if ($status -ne 200) {
    throw "gateway /health not 200, got $status"
  }

  $inst = Get-HeaderValue -HeaderLines $headers -Name 'X-Backend-Instance'
  if (-not [string]::IsNullOrWhiteSpace($inst)) {
    $seen.Add($inst) | Out-Null
  }
  Start-Sleep -Milliseconds 150
}

if ($seen.Count -lt 1) {
  throw "gateway response missing X-Backend-Instance"
}
Write-Host "  seen instances via gateway: $([string]::Join(', ', $seen))"

Write-Host "[4/7] Check gateway API auth path"
$code = (& curl.exe -k -s -o NUL -w "%{http_code}" -H "Authorization: Bearer $apiKey" "$GatewayBase/api/device_status")
if ([int]$code -ne 200) {
  throw "gateway /api/device_status expected 200, got $code"
}
Write-Host "  gateway api ok"

Write-Host "[5/7] Failover drill: stop backend_api_1, gateway should stay healthy"
$stopped = $false
try {
  docker stop mf_backend_api_1 | Out-Null
  $stopped = $true
  Start-Sleep -Seconds 3

  $ok = $false
  for ($i = 0; $i -lt 15; $i++) {
    $headers = & curl.exe -k -s -D - -o NUL "$GatewayBase/health"
    $status = Get-StatusCodeFromHeaders -HeaderLines $headers
    $inst = Get-HeaderValue -HeaderLines $headers -Name 'X-Backend-Instance'

    if ($status -eq 200 -and $inst -eq 'backend-api-2') {
      $ok = $true
      break
    }
    Start-Sleep -Seconds 1
  }

  if (-not $ok) {
    throw "failover check failed: gateway did not switch to backend-api-2"
  }
  Write-Host "  failover ok"
}
finally {
  if ($stopped) {
    docker start mf_backend_api_1 | Out-Null

    $recovered = $false
    for ($i = 0; $i -lt 20; $i++) {
      try {
        $h = Invoke-RestMethod "http://127.0.0.1:18001/health" -Method Get
        if ($h.instance_id -eq 'backend-api-1') {
          $recovered = $true
          break
        }
      } catch {
      }
      Start-Sleep -Seconds 1
    }

    if (-not $recovered) {
      throw "backend_api_1 did not recover in time"
    }
  }
}

Write-Host "[6/7] Verify single ingestion role (APIs off, worker on)"
$mApi1 = (Invoke-WebRequest "http://127.0.0.1:18001/metrics" -UseBasicParsing).Content
$mApi2 = (Invoke-WebRequest "http://127.0.0.1:18002/metrics" -UseBasicParsing).Content
$mWorker = (Invoke-WebRequest "http://127.0.0.1:18003/metrics" -UseBasicParsing).Content

$vApi1 = Get-MetricValue -Metrics $mApi1 -MetricName 'mf_mqtt_connected'
$vApi2 = Get-MetricValue -Metrics $mApi2 -MetricName 'mf_mqtt_connected'
$vWorker = Get-MetricValue -Metrics $mWorker -MetricName 'mf_mqtt_connected'

if ($null -eq $vApi1 -or $null -eq $vApi2 -or $null -eq $vWorker) {
  throw "metric mf_mqtt_connected missing on one or more instances"
}
if ($vApi1 -ne 0 -or $vApi2 -ne 0) {
  throw "API instances should not ingest MQTT: api1=$vApi1 api2=$vApi2"
}
if ($vWorker -lt 1) {
  throw "worker should ingest MQTT: worker=$vWorker"
}
Write-Host "  ingestion role split ok (api1=$vApi1, api2=$vApi2, worker=$vWorker)"

Write-Host "[7/7] PASS: P2-1 backend HA baseline works"