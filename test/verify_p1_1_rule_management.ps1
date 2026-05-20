Param(
  [string]$EnvFile = ".env.dev",
  [string]$ApiBase = "http://127.0.0.1:8000",
  [int]$WaitSeconds = 15
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $EnvFile)) { throw "Env file not found: $EnvFile" }

$envMap = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
  $parts = $_.Split('=', 2)
  $envMap[$parts[0].Trim()] = $parts[1]
}

$apiKey = $envMap["API_KEY"]
if (-not $apiKey) { throw "API_KEY missing in $EnvFile" }
$headers = @{ Authorization = "Bearer $apiKey" }

$tag = Get-Date -Format "HHmmss"
$ruleCode = "p1_speed_dynamic_$tag"
$aiboxId = "P1RULE_$tag"
$camId = "CAM_$tag"

function Publish-Speed {
  param(
    [string]$Aibox,
    [string]$Cam
  )

  $iso = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $speedPayloadObj = @{
    aibox_id = $Aibox
    cam_id = $Cam
    timestamp = $iso
    disaster_type = "flood"
    speed = @(2.4, 2.5, 2.6, 2.7)
  }
  $speedPayload = $speedPayloadObj | ConvertTo-Json -Compress

  $null = $speedPayload | docker exec -i mf_mqtt mosquitto_pub -h 127.0.0.1 -p 1883 -t "disaster_monitoring/$Aibox/speed" -q 1 -s
  if ($LASTEXITCODE -ne 0) { throw "Failed to publish speed payload" }
}

function Convert-ToAlarmArray {
  param(
    [Parameter(Mandatory = $false)]
    $Raw
  )

  if ($null -eq $Raw) { return @() }

  $arr = @($Raw)

  # Guard for wrapped payloads: { value: [...] }
  if ($arr.Count -eq 1 -and $arr[0] -and $arr[0].PSObject.Properties["value"]) {
    $arr = @($arr[0].value)
  }

  return @($arr)
}

function Get-RuleOpenAlarms {
  param(
    [string]$QueryUrl,
    [string]$RuleCode,
    [hashtable]$AuthHeaders
  )

  $raw = Invoke-RestMethod $QueryUrl -Headers $AuthHeaders -Method Get
  $all = Convert-ToAlarmArray -Raw $raw

  # Ignore unexpected objects without rule_code (e.g., error-like payload)
  $allAlarmObjects = @($all | Where-Object { $_ -and $_.PSObject.Properties["rule_code"] })
  $target = @($allAlarmObjects | Where-Object { $_.rule_code -eq $RuleCode })

  return @{
    all = $allAlarmObjects
    target = $target
  }
}

function Get-MaxAlarmId {
  param(
    [array]$Alarms
  )

  $ids = @(
    $Alarms |
      Where-Object { $_ -and $_.PSObject.Properties["id"] } |
      ForEach-Object { [int]$_.id }
  )

  if ($ids.Count -eq 0) {
    $sample = $Alarms | ConvertTo-Json -Depth 8 -Compress
    throw "Alarms returned but no 'id' field found. sample=$sample"
  }

  return (($ids | Measure-Object -Maximum).Maximum)
}

Write-Host "[1/8] Check MQTT connected metric"
$metrics = Invoke-WebRequest "$ApiBase/metrics" -UseBasicParsing
if (-not ($metrics.Content -match "mf_mqtt_connected\s+1")) {
  throw "MQTT is not connected in backend"
}
Write-Host "  mqtt connected=1"

Write-Host "[2/8] Create dynamic speed rule (high threshold, expect no alarm)"
$createBodyObj = @{
  rule_code = $ruleCode
  name = "Dynamic speed rule $tag"
  event_type = "speed"
  severity = "medium"
  enabled = $true
  cooldown_seconds = 60
  condition_json = @{ min_avg_speed = 3.0 }
}
$createBody = $createBodyObj | ConvertTo-Json -Compress
$createdRule = Invoke-RestMethod "$ApiBase/api/alarm_rules" -Headers $headers -Method Post -ContentType "application/json" -Body $createBody
Write-Host "  created rule id=$($createdRule.id), code=$($createdRule.rule_code)"

$alarmQueryBase = "$ApiBase/api/alarms?status=open&aibox_id=$aiboxId&cam_id=$camId"

Write-Host "[3/8] Publish speed once (should NOT trigger dynamic rule)"
Publish-Speed -Aibox $aiboxId -Cam $camId
Start-Sleep -Seconds 2

$snapshot1 = Get-RuleOpenAlarms -QueryUrl $alarmQueryBase -RuleCode $ruleCode -AuthHeaders $headers
$alarmsAfterFirst = @($snapshot1.target)
$otherRuleCount = @($snapshot1.all | Where-Object { $_.rule_code -ne $ruleCode }).Count
if ($alarmsAfterFirst.Count -ne 0) {
  throw "Expected 0 alarms for dynamic rule before lowering threshold, got $($alarmsAfterFirst.Count)"
}
Write-Host "  no dynamic-rule alarm as expected (other open alarms=$otherRuleCount)"

Write-Host "[4/8] Update rule threshold to trigger"
$updateBodyObj = @{
  name = "Dynamic speed rule $tag"
  event_type = "speed"
  severity = "medium"
  enabled = $true
  cooldown_seconds = 60
  condition_json = @{ min_avg_speed = 1.0 }
}
$updateBody = $updateBodyObj | ConvertTo-Json -Compress
$updatedRule = Invoke-RestMethod "$ApiBase/api/alarm_rules/$($createdRule.id)" -Headers $headers -Method Put -ContentType "application/json" -Body $updateBody
Write-Host "  updated min_avg_speed=$($updatedRule.condition_json.min_avg_speed)"

Write-Host "[5/8] Publish speed again (should trigger dynamic rule)"
Publish-Speed -Aibox $aiboxId -Cam $camId

$newAlarms = @()
for ($i = 0; $i -lt $WaitSeconds; $i++) {
  $snapshotN = Get-RuleOpenAlarms -QueryUrl $alarmQueryBase -RuleCode $ruleCode -AuthHeaders $headers
  $newAlarms = @($snapshotN.target)
  if ($newAlarms.Count -gt 0) { break }
  Start-Sleep -Seconds 1
}
if ($newAlarms.Count -eq 0) {
  throw "Expected dynamic-rule alarms after lowering threshold, got 0"
}
$maxId = Get-MaxAlarmId -Alarms $newAlarms
Write-Host "  alarm generated count=$($newAlarms.Count), max_id=$maxId"

Write-Host "[6/8] Disable rule"
$disableBody = @{ enabled = $false } | ConvertTo-Json -Compress
$disabledRule = Invoke-RestMethod "$ApiBase/api/alarm_rules/$($createdRule.id)/enabled" -Headers $headers -Method Patch -ContentType "application/json" -Body $disableBody
if ($disabledRule.enabled -ne $false) {
  throw "Rule disable failed"
}
Write-Host "  rule disabled"

Write-Host "[7/8] Publish speed again (should NOT create new dynamic-rule alarm)"
Publish-Speed -Aibox $aiboxId -Cam $camId
Start-Sleep -Seconds 3
$afterDisable = @((Get-RuleOpenAlarms -QueryUrl $alarmQueryBase -RuleCode $ruleCode -AuthHeaders $headers).target)
$newer = @(
  $afterDisable |
    Where-Object { $_ -and $_.PSObject.Properties["id"] -and ([int]$_.id -gt [int]$maxId) }
)
if ($newer.Count -gt 0) {
  throw "Rule disabled but new alarms still generated: $($newer.Count)"
}
Write-Host "  no new dynamic-rule alarms after disable"

Write-Host "[8/8] PASS: P1-1 rule management works"
