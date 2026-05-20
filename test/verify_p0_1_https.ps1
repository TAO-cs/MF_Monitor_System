Param(
  [string]$ApiKey = ""
)

$ErrorActionPreference = "Stop"

if (-not $ApiKey) {
  if (Test-Path ".env") {
    $line = Get-Content ".env" | Where-Object { $_ -match '^API_KEY=' } | Select-Object -First 1
    if ($line) { $ApiKey = $line.Substring(8) }
  }
}
if (-not $ApiKey) { throw "API_KEY not found. Pass -ApiKey or set API_KEY in .env" }

Write-Host "[1/4] HTTP -> HTTPS redirect"
$redirect = curl.exe -sS -I http://127.0.0.1/health 2>&1
$redirect | Select-String -Pattern "HTTP/|Location" | ForEach-Object { $_.Line }

Write-Host "`n[2/4] HTTPS health"
$health = curl.exe -sS -k https://127.0.0.1/health 2>&1
Write-Host $health

Write-Host "`n[3/4] HTTPS /api without key (should be 401)"
$unauth = curl.exe -sS -k -i https://127.0.0.1/api/device_status 2>&1
($unauth | Select-String -Pattern "HTTP/|Missing Authorization|Invalid API key") | ForEach-Object { $_.Line }

Write-Host "`n[4/4] HTTPS /api with key (should be 200)"
$auth = curl.exe -sS -k -i -H "Authorization: Bearer $ApiKey" https://127.0.0.1/api/device_status 2>&1
($auth | Select-String -Pattern 'HTTP/|"aibox_id"|"cam_id"') | Select-Object -First 10 | ForEach-Object { $_.Line }
