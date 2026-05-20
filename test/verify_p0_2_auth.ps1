Param(
  [string]$BaseUrl = "http://127.0.0.1:8000"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path ".env")) {
  throw ".env not found"
}

function Get-EnvValue([string]$Key) {
  $line = Get-Content ".env" | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
  if (-not $line) { return "" }
  return $line.Substring($Key.Length + 1)
}

$primary = Get-EnvValue "API_KEY"
$backupCsv = Get-EnvValue "API_KEYS"
$disabledCsv = Get-EnvValue "API_KEYS_DISABLED"

$backups = @()
if ($backupCsv) {
  $backups = @($backupCsv.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}
$disabled = @()
if ($disabledCsv) {
  $disabled = @($disabledCsv.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

Write-Host "[1/5] Missing header => expect 401"
try {
  Invoke-RestMethod "$BaseUrl/api/device_status" -Method Get | Out-Null
  Write-Host "  FAIL: expected 401, got success"
} catch {
  Write-Host "  PASS: $($_.ErrorDetails.Message)"
}

Write-Host "[2/5] Wrong key => expect 401"
try {
  Invoke-RestMethod "$BaseUrl/api/device_status" -Headers @{Authorization="Bearer wrong-key"} -Method Get | Out-Null
  Write-Host "  FAIL: expected 401, got success"
} catch {
  Write-Host "  PASS: $($_.ErrorDetails.Message)"
}

Write-Host "[3/5] Primary key => expect 200"
if (-not $primary) { throw "API_KEY is empty" }
$data = Invoke-RestMethod "$BaseUrl/api/device_status" -Headers @{Authorization="Bearer $primary"} -Method Get
Write-Host "  PASS: returned count=$($data.Count)"

Write-Host "[4/5] Backup key => expect 200 (if exists)"
if ($backups.Count -gt 0) {
  $bk = $backups[0]
  $data2 = Invoke-RestMethod "$BaseUrl/api/device_status" -Headers @{Authorization="Bearer $bk"} -Method Get
  Write-Host "  PASS: backup accepted, count=$($data2.Count)"
} else {
  Write-Host "  SKIP: no API_KEYS configured"
}

Write-Host "[5/5] Disabled key => expect 401 (if exists)"
if ($disabled.Count -gt 0) {
  $dk = $disabled[0]
  try {
    Invoke-RestMethod "$BaseUrl/api/device_status" -Headers @{Authorization="Bearer $dk"} -Method Get | Out-Null
    Write-Host "  FAIL: expected 401, got success"
  } catch {
    Write-Host "  PASS: $($_.ErrorDetails.Message)"
  }
} else {
  Write-Host "  SKIP: no API_KEYS_DISABLED configured"
}
