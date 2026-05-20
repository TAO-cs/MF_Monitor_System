Param(
  [string]$EnvFile = ".env.dev",
  [string]$AiboxId = "",
  [string]$CamId = "",
  [string]$ApiBase = "http://127.0.0.1:8000",
  [int]$WaitSeconds = 20
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $EnvFile)) { throw "Env file not found: $EnvFile" }

function As-Array {
  param([object]$Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Array]) { return $Value }
  return @($Value)
}

$runTag = Get-Date -Format "HHmmss"
if (-not $AiboxId) { $AiboxId = "P1TEST_$runTag" }
if (-not $CamId) { $CamId = "CAM_$runTag" }

Write-Host "Test target => aibox_id=$AiboxId, cam_id=$CamId"

$envMap = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
  $parts = $_.Split('=', 2)
  $envMap[$parts[0].Trim()] = $parts[1]
}

$apiKey = $envMap["API_KEY"]
if (-not $apiKey) { throw "API_KEY missing in $EnvFile" }
$headers = @{ Authorization = "Bearer $apiKey" }

Write-Host "[1/8] Check alarm rules"
$rules = Invoke-RestMethod "$ApiBase/api/alarm_rules?enabled=true" -Headers $headers -Method Get
$ruleCodes = @($rules | ForEach-Object { $_.rule_code })
Write-Host "  enabled rule count=$($ruleCodes.Count)"

$need = @("cls_high_conf_flood", "device_offline")
foreach ($rc in $need) {
  if ($ruleCodes -notcontains $rc) {
    throw "Missing required rule: $rc"
  }
}

Write-Host "[2/8] Check MQTT connected metric"
$metrics = Invoke-WebRequest "$ApiBase/metrics" -UseBasicParsing
$isConnected = $metrics.Content -match "mf_mqtt_connected\s+1"
if (-not $isConnected) {
  throw "MQTT is not connected in backend (/metrics -> mf_mqtt_connected != 1)"
}
Write-Host "  mqtt connected=1"

Write-Host "[3/8] Snapshot alarms before publish"
$baseUrl = "$ApiBase/api/alarms?aibox_id=$AiboxId&cam_id=$CamId"
$beforeRaw = Invoke-RestMethod $baseUrl -Headers $headers -Method Get
$beforeAlarms = @(As-Array $beforeRaw | Where-Object {
  $_ -ne $null -and $_.PSObject.Properties.Name -contains "id"
})
$beforeMaxId = 0
if ($beforeAlarms.Count -gt 0) {
  $beforeMaxId = [int](($beforeAlarms | Sort-Object { [int]$_.id } -Descending | Select-Object -First 1).id)
}
Write-Host "  existing alarms for target=$($beforeAlarms.Count), before_max_id=$beforeMaxId"

Write-Host "[4/8] Build payloads"
$now = Get-Date
$iso = $now.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$disasterId = "p1_cls_" + (Get-Date -Format "yyyyMMddHHmmss")
$clsPayloadObj = @{
  disaster_id = $disasterId
  disaster_type = "flood"
  timestamp = $iso
  confidence = 0.98
  aibox_id = $AiboxId
  cam_id = $CamId
  image_path = "https://storage.server/data/images/p1_cls.jpg"
}
$offPayloadObj = @{
  aibox_id = $AiboxId
  cam_id = $CamId
  online_status = "off"
  timestamp = $iso
}
$clsPayload = $clsPayloadObj | ConvertTo-Json -Compress
$offPayload = $offPayloadObj | ConvertTo-Json -Compress

Write-Host "[5/8] Publish classification (stdin mode)"
$null = $clsPayload | docker exec -i mf_mqtt mosquitto_pub -h 127.0.0.1 -p 1883 -t "disaster_monitoring/$AiboxId/classification" -q 1 -s
if ($LASTEXITCODE -ne 0) { throw "Failed to publish classification payload" }

Write-Host "[6/8] Publish device_status (stdin mode)"
$null = $offPayload | docker exec -i mf_mqtt mosquitto_pub -h 127.0.0.1 -p 1883 -t "disaster_monitoring/$AiboxId/device_status" -q 1 -s
if ($LASTEXITCODE -ne 0) { throw "Failed to publish device_status payload" }

Write-Host "[7/8] Poll alarms (up to $WaitSeconds s)"
$newAlarms = @()
$foundCls = $false
$foundOff = $false
for ($i = 0; $i -lt $WaitSeconds; $i++) {
  $allRaw = Invoke-RestMethod $baseUrl -Headers $headers -Method Get
  $all = @(As-Array $allRaw | Where-Object {
    $_ -ne $null -and $_.PSObject.Properties.Name -contains "id"
  })
  $newAlarms = @($all | Where-Object { [int]$_.id -gt $beforeMaxId })
  $newRuleCodes = @($newAlarms | ForEach-Object { $_.rule_code })
  $foundCls = $newRuleCodes -contains "cls_high_conf_flood"
  $foundOff = $newRuleCodes -contains "device_offline"
  if ($foundCls -and $foundOff) {
    break
  }
  Start-Sleep -Seconds 1
}

Write-Host "  new alarm count=$($newAlarms.Count)"
if ($newAlarms.Count -gt 0) {
  $newAlarms | Select-Object id,rule_code,event_type,severity,status,triggered_at | Format-Table | Out-String | Write-Host
}

if (-not $foundCls) {
  throw "No new alarm generated for cls_high_conf_flood"
}
if (-not $foundOff) {
  throw "No new alarm generated for device_offline"
}

Write-Host "[8/8] PASS: P1-1 alarm engine baseline works"
