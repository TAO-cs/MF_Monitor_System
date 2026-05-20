Param(
  [string]$EnvFile = "",
  [string]$ApiBase = "",
  [string]$GatewayBase = "https://127.0.0.1",
  [int]$WaitSeconds = 25
)

$ErrorActionPreference = "Stop"

if (-not $EnvFile) {
  if (Test-Path ".env.dev.ha.mqtt.dbha") { $EnvFile = ".env.dev.ha.mqtt.dbha" }
  elseif (Test-Path ".env.dev.ha") { $EnvFile = ".env.dev.ha" }
  elseif (Test-Path ".env.dev") { $EnvFile = ".env.dev" }
  else { $EnvFile = ".env" }
}

if (-not (Test-Path $EnvFile)) {
  throw "Env file not found: $EnvFile"
}

if (-not $ApiBase) {
  if ($EnvFile -like "*.ha*") { $ApiBase = "http://127.0.0.1:18001" }
  else { $ApiBase = "http://127.0.0.1:8000" }
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
$headers = @{ Authorization = "Bearer $apiKey" }

function Invoke-CurlText {
  param(
    [string]$Url,
    [string[]]$HeaderLines = @()
  )

  $tempFile = Join-Path $env:TEMP ("p25_curl_" + [guid]::NewGuid().ToString('N') + ".tmp")
  try {
    $args = @('-k', '-s', '-o', $tempFile, '-w', '%{http_code}')
    foreach ($line in $HeaderLines) {
      $args += @('-H', $line)
    }
    $args += $Url

    $status = (& curl.exe @args)
    if ($LASTEXITCODE -ne 0) {
      throw "curl request failed for $Url"
    }

    $content = ''
    if (Test-Path $tempFile) {
      $content = Get-Content $tempFile -Raw -Encoding UTF8
    }

    return [pscustomobject]@{
      StatusCode = [int]$status
      Content = $content
    }
  }
  finally {
    if (Test-Path $tempFile) {
      Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
  }
}

$mqttHost = if ($envMap['MQTT_BROKER_HOST']) { $envMap['MQTT_BROKER_HOST'] } else { '127.0.0.1' }
if ($mqttHost -in @('mqtt', 'mqtt_primary', 'mqtt_secondary', 'mysql', 'mysql_replica')) {
  $mqttHost = '127.0.0.1'
}
$mqttPort = if ($envMap['MQTT_BROKER_PORT']) { [int]$envMap['MQTT_BROKER_PORT'] } else { 1883 }
$mqttUser = $envMap['MQTT_USERNAME']
$mqttPassword = $envMap['MQTT_PASSWORD']

function Get-PythonExe {
  $candidates = @(
    '.\venv_MFSystem\Scripts\python.exe',
    '.\venv_mfsystem\Scripts\python.exe',
    'python'
  )
  foreach ($candidate in $candidates) {
    try {
      if ($candidate -eq 'python') {
        $null = & $candidate -c "print('ok')" 2>$null
        if ($LASTEXITCODE -eq 0) { return $candidate }
      } elseif (Test-Path $candidate) {
        return $candidate
      }
    } catch {
    }
  }
  throw 'Python executable not found for MQTT publish helper'
}

$PythonExe = Get-PythonExe

function As-Array {
  param([Parameter(Mandatory = $false)]$Value)
  if ($null -eq $Value) { return @() }
  return @($Value)
}

function Sum-Field {
  param(
    [array]$Items,
    [string]$FieldName
  )

  $sum = 0
  foreach ($item in (As-Array $Items)) {
    $value = $item.$FieldName
    if ($null -ne $value) {
      $sum += [double]$value
    }
  }
  return $sum
}

function Publish-MqttJson {
  param(
    [string]$Topic,
    [string]$Payload,
    [string]$ClientId
  )

  $env:P25_MQTT_HOST = $mqttHost
  $env:P25_MQTT_PORT = "$mqttPort"
  $env:P25_MQTT_USER = "$mqttUser"
  $env:P25_MQTT_PASSWORD = "$mqttPassword"
  $env:P25_MQTT_TOPIC = $Topic
  $env:P25_MQTT_PAYLOAD = $Payload
  $env:P25_MQTT_CLIENT_ID = $ClientId

  @"
import os
from paho.mqtt.publish import single

auth = None
if os.getenv("P25_MQTT_USER"):
    auth = {
        "username": os.getenv("P25_MQTT_USER"),
        "password": os.getenv("P25_MQTT_PASSWORD", ""),
    }

single(
    os.environ["P25_MQTT_TOPIC"],
    payload=os.environ["P25_MQTT_PAYLOAD"],
    qos=1,
    hostname=os.environ["P25_MQTT_HOST"],
    port=int(os.environ["P25_MQTT_PORT"]),
    auth=auth,
    client_id=os.environ["P25_MQTT_CLIENT_ID"],
)
"@ | & $PythonExe -

  if ($LASTEXITCODE -ne 0) {
    throw "Failed to publish topic: $Topic"
  }
}

$tag = Get-Date -Format "HHmmss"
$ruleCode = "p25_cls_$tag"
$aiboxId = "P25_$tag"
$camId = "CAM_$tag"
$deviceName = "P2-5 Device $tag"
$locationName = "p2_5_visual_$tag"
$disasterId = "p25_cls_evt_$tag"
$ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

Write-Host "[1/9] Check dashboard page through gateway"
$pageResp = Invoke-CurlText -Url "$GatewayBase/dashboard"
if ([int]$pageResp.StatusCode -ne 200) {
  throw "dashboard page expected 200, got $($pageResp.StatusCode)"
}
$pageHtml = $pageResp.Content
if ($pageHtml -notmatch 'api/dashboard/summary' -or $pageHtml -notmatch 'id="cards"') {
  throw "dashboard html content check failed"
}
Write-Host "  dashboard html ok"

Write-Host "[2/9] Check dashboard API auth path via gateway"
$unauthResp = Invoke-CurlText -Url "$GatewayBase/api/dashboard/summary?hours=6"
if ([int]$unauthResp.StatusCode -ne 401) {
  throw "gateway summary without key expected 401, got $($unauthResp.StatusCode)"
}
$authResp = Invoke-CurlText -Url "$GatewayBase/api/dashboard/summary?hours=6" -HeaderLines @("Authorization: Bearer $apiKey")
if ([int]$authResp.StatusCode -ne 200) {
  throw "gateway summary with key expected 200, got $($authResp.StatusCode)"
}
Write-Host "  gateway auth ok"

Write-Host "[3/9] Snapshot baseline summary and trends"
$beforeSummary = Invoke-RestMethod "$ApiBase/api/dashboard/summary?hours=6" -Headers $headers -Method Get
$beforeTrends = Invoke-RestMethod "$ApiBase/api/dashboard/trends?hours=6&bucket_minutes=30" -Headers $headers -Method Get
$beforeClassTotal = Sum-Field -Items (As-Array $beforeTrends.buckets) -FieldName 'classification_count'
$beforeSpeedTotal = Sum-Field -Items (As-Array $beforeTrends.buckets) -FieldName 'speed_count'
$beforeAlarmTotal = Sum-Field -Items (As-Array $beforeTrends.buckets) -FieldName 'alarm_count'
Write-Host "  baseline totals => classification=$beforeClassTotal, speed=$beforeSpeedTotal, alarm=$beforeAlarmTotal"

Write-Host "[4/9] Create dedicated rule and device"
$ruleBody = @{
  rule_code = $ruleCode
  name = "P2-5 visualization rule $tag"
  event_type = "classification"
  severity = "high"
  enabled = $true
  cooldown_seconds = 0
  condition_json = @{ disaster_type = "flood"; min_confidence = 0.95 }
} | ConvertTo-Json -Compress -Depth 8
$rule = Invoke-RestMethod "$ApiBase/api/alarm_rules" -Headers $headers -Method Post -ContentType "application/json" -Body $ruleBody
if (-not $rule.id) { throw "Create alarm rule failed" }

$deviceBody = @{
  aibox_id = $aiboxId
  cam_id = $camId
  device_name = $deviceName
  device_type = "monitor_node"
  enabled = $true
  allow_config_push = $true
  allow_remote_control = $false
  metadata_json = @{ source = "verify_p2_5"; stage = "visualization" }
  location = $locationName
  latitude = 31.2304
  longitude = 121.4737
} | ConvertTo-Json -Compress -Depth 8
$device = Invoke-RestMethod "$ApiBase/api/devices" -Headers $headers -Method Post -ContentType "application/json" -Body $deviceBody
if (-not $device.id) { throw "Create device failed" }
Write-Host "  rule id=$($rule.id), device id=$($device.id)"

Write-Host "[5/9] Publish device_status, classification and speed"
$deviceStatusPayload = @{
  aibox_id = $aiboxId
  cam_id = $camId
  online_status = "on"
  timestamp = $ts
} | ConvertTo-Json -Compress
Publish-MqttJson -Topic "disaster_monitoring/$aiboxId/device_status" -Payload $deviceStatusPayload -ClientId "verify-p25-status-$tag"

$classificationPayload = @{
  disaster_id = $disasterId
  disaster_type = "flood"
  timestamp = $ts
  confidence = 0.98
  aibox_id = $aiboxId
  cam_id = $camId
  image_path = "https://storage.server/data/images/p25_dashboard.jpg"
} | ConvertTo-Json -Compress
Publish-MqttJson -Topic "disaster_monitoring/$aiboxId/classification" -Payload $classificationPayload -ClientId "verify-p25-cls-$tag"

$speedPayload = @{
  aibox_id = $aiboxId
  cam_id = $camId
  timestamp = $ts
  disaster_type = "flood"
  speed = @(1.91, 2.02, 1.88, 2.11)
} | ConvertTo-Json -Compress -Depth 8
Publish-MqttJson -Topic "disaster_monitoring/$aiboxId/speed" -Payload $speedPayload -ClientId "verify-p25-speed-$tag"
Write-Host "  mqtt publish ok"

Write-Host "[6/9] Poll summary, map and alarm board readiness"
$summary = $null
$deviceItem = $null
$mapPoint = $null
$latestAlarms = @()
for ($i = 0; $i -lt $WaitSeconds; $i++) {
  Start-Sleep -Seconds 1
  $summary = Invoke-RestMethod "$ApiBase/api/dashboard/summary?hours=6" -Headers $headers -Method Get
  $devices = As-Array $summary.devices
  $deviceItem = $devices | Where-Object { $_.aibox_id -eq $aiboxId -and $_.cam_id -eq $camId } | Select-Object -First 1
  $mapPoint = (As-Array $summary.map_points) | Where-Object { $_.aibox_id -eq $aiboxId -and $_.cam_id -eq $camId } | Select-Object -First 1
  $latestAlarms = As-Array $summary.latest_alarms

  if ($deviceItem -and $mapPoint -and $latestAlarms.Count -ge 1 -and [int]$deviceItem.classification_count_window -ge 1 -and [int]$deviceItem.speed_count_window -ge 1 -and [int]$deviceItem.open_alarm_count -ge 1) {
    break
  }
}
if (-not $deviceItem) { throw "summary device row not found for $aiboxId / $camId" }
if (-not $mapPoint) { throw "map point not found for $aiboxId / $camId" }
if ($latestAlarms.Count -lt 1) { throw "latest_alarms should not be empty" }
if ([int]$deviceItem.classification_count_window -lt 1) { throw "device classification count not updated" }
if ([int]$deviceItem.speed_count_window -lt 1) { throw "device speed count not updated" }
if ([int]$deviceItem.open_alarm_count -lt 1) { throw "device open alarm count not updated" }
Write-Host "  summary ok (classification=$($deviceItem.classification_count_window), speed=$($deviceItem.speed_count_window), open_alarm=$($deviceItem.open_alarm_count))"

Write-Host "[7/9] Verify trends increased"
$afterTrends = Invoke-RestMethod "$ApiBase/api/dashboard/trends?hours=6&bucket_minutes=30" -Headers $headers -Method Get
$afterBuckets = As-Array $afterTrends.buckets
if ($afterBuckets.Count -lt 1) {
  throw "trend buckets should not be empty"
}
$afterClassTotal = Sum-Field -Items $afterBuckets -FieldName 'classification_count'
$afterSpeedTotal = Sum-Field -Items $afterBuckets -FieldName 'speed_count'
$afterAlarmTotal = Sum-Field -Items $afterBuckets -FieldName 'alarm_count'
if ($afterClassTotal -le $beforeClassTotal) { throw "classification trend total did not increase" }
if ($afterSpeedTotal -le $beforeSpeedTotal) { throw "speed trend total did not increase" }
if ($afterAlarmTotal -le $beforeAlarmTotal) { throw "alarm trend total did not increase" }
Write-Host "  trend totals => classification=$afterClassTotal, speed=$afterSpeedTotal, alarm=$afterAlarmTotal"

Write-Host "[8/9] Verify report export"
$csvResp = Invoke-CurlText -Url "$GatewayBase/api/dashboard/report.csv?hours=6" -HeaderLines @("Authorization: Bearer $apiKey")
if ([int]$csvResp.StatusCode -ne 200) {
  throw "csv export expected 200, got $($csvResp.StatusCode)"
}
$csvText = $csvResp.Content
if ($csvText -notmatch 'aibox_id,cam_id,device_name') {
  throw "csv header missing"
}
if ($csvText -notmatch [regex]::Escape($aiboxId) -or $csvText -notmatch [regex]::Escape($camId)) {
  throw "csv does not contain test device"
}
Write-Host "  csv export ok"

Write-Host "[9/9] PASS: P2-5 visualization baseline works"
