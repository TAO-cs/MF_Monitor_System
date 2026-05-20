Param(
  [string]$BaseUrl = "http://127.0.0.1:8000"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path ".env.dev")) {
  throw ".env.dev not found"
}

$keyLine = Get-Content ".env.dev" | Where-Object { $_ -match '^API_KEY=' } | Select-Object -First 1
if (-not $keyLine) { throw "API_KEY not found in .env.dev" }
$key = $keyLine.Substring(8)
$headers = @{ Authorization = "Bearer $key" }

Write-Host "[1/4] Check health"
Invoke-RestMethod "$BaseUrl/health" -Method Get | ConvertTo-Json -Compress | Write-Host

Write-Host "[2/4] Trigger 401 and 200"
try {
  Invoke-RestMethod "$BaseUrl/api/device_status" -Method Get | Out-Null
} catch {
  Write-Host "  401 path ok"
}
Invoke-RestMethod "$BaseUrl/api/device_status" -Method Get -Headers $headers | Out-Null
Write-Host "  200 path ok"

Write-Host "[3/4] Read /metrics"
$metrics = Invoke-WebRequest "$BaseUrl/metrics" -Method Get -UseBasicParsing
if ($metrics.StatusCode -ne 200) { throw "/metrics not 200" }

$patterns = @(
  '^mf_http_requests_total',
  '^mf_http_4xx_total',
  '^mf_http_request_duration_seconds_count',
  '^mf_mqtt_connected',
  '^mf_mqtt_messages_total'
)
foreach ($p in $patterns) {
  $hit = ($metrics.Content -split "`n") | Where-Object { $_ -match $p } | Select-Object -First 2
  if ($hit) {
    $hit | ForEach-Object { Write-Host "  $_" }
  } else {
    Write-Host "  MISSING: $p"
  }
}

Write-Host "[4/4] PASS (check no MISSING above)"
