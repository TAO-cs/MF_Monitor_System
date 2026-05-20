Param(
  [string]$EnvFile = "",
  [string]$ApiBase = "",
  [int]$WaitSeconds = 20
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

function Get-ErrorStatusCode {
  param($ErrorRecord)
  if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
    return [int]$ErrorRecord.Exception.Response.StatusCode.value__
  }
  return 0
}

function Publish-DeviceStatus {
  param(
    [string]$AiboxId,
    [string]$CamId,
    [string]$OnlineStatus
  )

  $payloadObj = @{
    aibox_id = $AiboxId
    cam_id = $CamId
    online_status = $OnlineStatus
    timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  }
  $payload = $payloadObj | ConvertTo-Json -Compress

  $env:P24_MQTT_HOST = $mqttHost
  $env:P24_MQTT_PORT = "$mqttPort"
  $env:P24_MQTT_USER = "$mqttUser"
  $env:P24_MQTT_PASSWORD = "$mqttPassword"
  $env:P24_MQTT_TOPIC = "disaster_monitoring/$AiboxId/device_status"
  $env:P24_MQTT_PAYLOAD = $payload

  @"
import os
from paho.mqtt.publish import single

auth = None
if os.getenv("P24_MQTT_USER"):
    auth = {
        "username": os.getenv("P24_MQTT_USER"),
        "password": os.getenv("P24_MQTT_PASSWORD", ""),
    }

single(
    os.environ["P24_MQTT_TOPIC"],
    payload=os.environ["P24_MQTT_PAYLOAD"],
    qos=1,
    hostname=os.environ["P24_MQTT_HOST"],
    port=int(os.environ["P24_MQTT_PORT"]),
    auth=auth,
    client_id="verify-p2-4-device-status",
)
"@ | & $PythonExe -

  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to publish device_status payload via Python MQTT helper'
  }
}

$tag = Get-Date -Format "HHmmss"
$groupCode = "p24_grp_$tag"
$aiboxId = "P24_$tag"
$camId = "CAM_$tag"
$deviceName = "P2-4 Device $tag"
$groupName = "P2-4 Group $tag"
$locationName = "p2_4_lab_$tag"

Write-Host "[1/10] Create device group"
$groupBody = @{
  group_code = $groupCode
  group_name = $groupName
  description = "P2-4 device center verification group"
} | ConvertTo-Json -Compress
$group = Invoke-RestMethod "$ApiBase/api/device_groups" -Headers $headers -Method Post -ContentType "application/json" -Body $groupBody
if (-not $group.id) { throw "Create device group failed" }
Write-Host "  group id=$($group.id), code=$($group.group_code)"

Write-Host "[2/10] Create device"
$deviceBody = @{
  aibox_id = $aiboxId
  cam_id = $camId
  device_name = $deviceName
  device_type = "monitor_node"
  enabled = $true
  allow_config_push = $true
  allow_remote_control = $false
  metadata_json = @{ source = "verify_p2_4"; stage = "device_center" }
  location = $locationName
  latitude = 31.2304
  longitude = 121.4737
} | ConvertTo-Json -Compress -Depth 8
$device = Invoke-RestMethod "$ApiBase/api/devices" -Headers $headers -Method Post -ContentType "application/json" -Body $deviceBody
if (-not $device.id) { throw "Create device failed" }
Write-Host "  device id=$($device.id), aibox_id=$($device.aibox_id), cam_id=$($device.cam_id)"

Write-Host "[3/10] Query device list"
$deviceListRaw = Invoke-RestMethod "$ApiBase/api/devices?aibox_id=$aiboxId&cam_id=$camId" -Headers $headers -Method Get
$deviceList = @(As-Array $deviceListRaw)
if ($deviceList.Count -lt 1) { throw "Device list query returned 0 rows" }
Write-Host "  device list count=$($deviceList.Count)"

Write-Host "[4/10] Add device to group"
$membership = Invoke-RestMethod "$ApiBase/api/device_groups/$($group.id)/members/$($device.id)" -Headers $headers -Method Post
if ($membership.device_id -ne $device.id) { throw "Add group member failed" }
Write-Host "  membership ok"

Write-Host "[5/10] Publish device_status to backend worker"
Publish-DeviceStatus -AiboxId $aiboxId -CamId $camId -OnlineStatus "on"
Write-Host "  device_status published"

Write-Host "[6/10] Query device overview"
$overview = $null
for ($i = 0; $i -lt $WaitSeconds; $i++) {
  $overview = Invoke-RestMethod "$ApiBase/api/device_overview?aibox_id=$aiboxId&cam_id=$camId" -Headers $headers -Method Get
  if ($overview.items -and @($overview.items).Count -ge 1) {
    $candidate = @($overview.items)[0]
    if ($candidate.status -and $candidate.status.online_status -eq 'on') { break }
  }
  Start-Sleep -Seconds 1
}
if (-not $overview.items -or @($overview.items).Count -lt 1) {
  throw "Device overview query returned 0 rows"
}
$item = @($overview.items)[0]
if ($item.location.location -ne $locationName) { throw "Overview location mismatch" }
if ($item.status.online_status -ne 'on') { throw "Overview status mismatch" }
if (-not (@($item.groups | Where-Object { $_.group_code -eq $groupCode }).Count -ge 1)) { throw "Overview group binding missing" }
Write-Host "  overview ok (online=$($item.status.online_status), groups=$((@($item.groups)).Count))"

Write-Host "[7/10] Push device config"
$configBody = @{
  config_name = "sampling_profile"
  payload = @{ interval_seconds = 15; sensitivity = "high" }
  qos = 1
  retain = $false
} | ConvertTo-Json -Compress -Depth 8
$command = Invoke-RestMethod "$ApiBase/api/devices/$($device.id)/config" -Headers $headers -Method Post -ContentType "application/json" -Body $configBody
if ($command.status -ne 'published') { throw "Config push status expected published, got $($command.status)" }
Write-Host "  command id=$($command.id), status=$($command.status)"

Write-Host "[8/10] Verify device command list"
$cmdListRaw = Invoke-RestMethod "$ApiBase/api/device_commands?device_id=$($device.id)&status=published" -Headers $headers -Method Get
$cmdList = @(As-Array $cmdListRaw)
if ($cmdList.Count -lt 1) { throw "Device command query returned 0 rows" }
$latestCmd = $cmdList | Select-Object -First 1
if ($latestCmd.topic -notmatch "disaster_monitoring/$aiboxId/config/sampling_profile") {
  throw "Unexpected command topic: $($latestCmd.topic)"
}
Write-Host "  command query ok"

Write-Host "[9/10] Disable config permission and verify rejection"
$permBody = @{ allow_config_push = $false } | ConvertTo-Json -Compress
$perm = Invoke-RestMethod "$ApiBase/api/devices/$($device.id)/permissions" -Headers $headers -Method Patch -ContentType "application/json" -Body $permBody
if ($perm.allow_config_push -ne $false) { throw "Disable allow_config_push failed" }

$blocked = $false
try {
  Invoke-RestMethod "$ApiBase/api/devices/$($device.id)/config" -Headers $headers -Method Post -ContentType "application/json" -Body $configBody | Out-Null
} catch {
  $status = Get-ErrorStatusCode $_
  if ($status -eq 403) {
    $blocked = $true
  } else {
    throw
  }
}
if (-not $blocked) { throw "Config push should be rejected after permission disable" }
Write-Host "  permission reject ok (403)"

Write-Host "[10/10] Remove group member and PASS"
$rmResp = Invoke-RestMethod "$ApiBase/api/device_groups/$($group.id)/members/$($device.id)" -Headers $headers -Method Delete
if (-not $rmResp.ok) { throw "Delete device group member failed" }
Write-Host "PASS: P2-4 device center works"




