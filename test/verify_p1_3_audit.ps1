Param(
  [string]$EnvFile = ".env.dev",
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

function Get-AuditLogs {
  param(
    [string]$QueryUrl,
    [hashtable]$Headers
  )

  $raw = Invoke-RestMethod $QueryUrl -Headers $Headers -Method Get
  return @(As-Array $raw | Where-Object { $_ -ne $null -and $_.PSObject.Properties.Name -contains "id" })
}

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
$ruleCode = "p1_audit_cls_$tag"
$aiboxId = "P13_$tag"
$camId = "CAM_$tag"
$ruleId = 0

try {
  Write-Host "[1/8] Create dedicated rule"
  $createBody = @{
    rule_code = $ruleCode
    name = "P1-3 audit rule $tag"
    event_type = "classification"
    severity = "high"
    enabled = $true
    cooldown_seconds = 60
    condition_json = @{ disaster_type = "flood"; min_confidence = 0.97 }
  } | ConvertTo-Json -Compress
  $rule = Invoke-RestMethod "$ApiBase/api/alarm_rules" -Headers $headers -Method Post -ContentType "application/json" -Body $createBody
  $ruleId = [int]$rule.id
  Write-Host "  rule id=$ruleId"

  Write-Host "[2/8] Update rule"
  $updateBody = @{
    name = "P1-3 audit rule $tag updated"
    event_type = "classification"
    severity = "high"
    enabled = $true
    cooldown_seconds = 90
    condition_json = @{ disaster_type = "flood"; min_confidence = 0.97 }
  } | ConvertTo-Json -Compress
  $null = Invoke-RestMethod "$ApiBase/api/alarm_rules/$ruleId" -Headers $headers -Method Put -ContentType "application/json" -Body $updateBody
  Write-Host "  rule updated"

  Write-Host "[3/8] Publish classification to trigger alarm"
  $iso = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $disasterId = "p13_cls_" + (Get-Date -Format "yyyyMMddHHmmss")
  $payload = @{
    disaster_id = $disasterId
    disaster_type = "flood"
    timestamp = $iso
    confidence = 0.99
    aibox_id = $aiboxId
    cam_id = $camId
    image_path = "https://storage.server/data/images/p13_audit.jpg"
  } | ConvertTo-Json -Compress

  $null = $payload | docker exec -i mf_mqtt mosquitto_pub -h 127.0.0.1 -p 1883 -t "disaster_monitoring/$aiboxId/classification" -q 1 -s
  if ($LASTEXITCODE -ne 0) { throw "Failed to publish classification payload" }

  Write-Host "[4/8] Poll alarm and do ack/close"
  $alarm = $null
  for ($i = 0; $i -lt $WaitSeconds; $i++) {
    $alarmsRaw = Invoke-RestMethod "$ApiBase/api/alarms?rule_code=$ruleCode&aibox_id=$aiboxId&cam_id=$camId" -Headers $headers -Method Get
    $arr = @(As-Array $alarmsRaw | Where-Object { $_ -ne $null -and $_.PSObject.Properties.Name -contains "id" })
    if ($arr.Count -gt 0) {
      $alarm = $arr | Sort-Object { [int]$_.id } -Descending | Select-Object -First 1
      break
    }
    Start-Sleep -Seconds 1
  }
  if ($null -eq $alarm) { throw "No alarm generated for rule $ruleCode" }
  $alarmId = [int]$alarm.id
  Write-Host "  alarm id=$alarmId"

  $null = Invoke-RestMethod "$ApiBase/api/alarms/$alarmId/ack" -Headers $headers -Method Post
  $null = Invoke-RestMethod "$ApiBase/api/alarms/$alarmId/close" -Headers $headers -Method Post
  Write-Host "  alarm ack/close done"

  Write-Host "[5/8] Verify management audit actions"
  $createLogs = @()
  $updateLogs = @()
  $ackLogs = @()
  $closeLogs = @()

  for ($i = 0; $i -lt $WaitSeconds; $i++) {
    $createLogs = Get-AuditLogs -QueryUrl "$ApiBase/api/audit_logs?action=alarm_rule_create&entity_type=alarm_rule&entity_id=$ruleId" -Headers $headers
    $updateLogs = Get-AuditLogs -QueryUrl "$ApiBase/api/audit_logs?action=alarm_rule_update&entity_type=alarm_rule&entity_id=$ruleId" -Headers $headers
    $ackLogs = Get-AuditLogs -QueryUrl "$ApiBase/api/audit_logs?action=alarm_ack&entity_type=alarm&entity_id=$alarmId" -Headers $headers
    $closeLogs = Get-AuditLogs -QueryUrl "$ApiBase/api/audit_logs?action=alarm_close&entity_type=alarm&entity_id=$alarmId" -Headers $headers

    if ($createLogs.Count -gt 0 -and $updateLogs.Count -gt 0 -and $ackLogs.Count -gt 0 -and $closeLogs.Count -gt 0) {
      break
    }
    Start-Sleep -Seconds 1
  }

  if ($createLogs.Count -eq 0) { throw "Missing audit action: alarm_rule_create" }
  if ($updateLogs.Count -eq 0) { throw "Missing audit action: alarm_rule_update" }
  if ($ackLogs.Count -eq 0) { throw "Missing audit action: alarm_ack" }
  if ($closeLogs.Count -eq 0) { throw "Missing audit action: alarm_close" }

  $createId = [int](($createLogs | Sort-Object { [int]$_.id } -Descending | Select-Object -First 1).id)
  Write-Host "  audit actions found"

  Write-Host "[6/8] Verify API access audit"
  $apiAccess = Get-AuditLogs -QueryUrl "$ApiBase/api/audit_logs?action=api_access&path=/api/alarms" -Headers $headers
  if ($apiAccess.Count -eq 0) {
    throw "Missing api_access audit for /api/alarms"
  }
  Write-Host "  api_access count=$($apiAccess.Count)"

  Write-Host "[7/8] Verify append-only behavior"
  $null = Invoke-RestMethod "$ApiBase/api/device_status" -Headers $headers -Method Get
  Start-Sleep -Seconds 1
  $createLogsAfter = Get-AuditLogs -QueryUrl "$ApiBase/api/audit_logs?action=alarm_rule_create&entity_type=alarm_rule&entity_id=$ruleId" -Headers $headers
  $idsAfter = @($createLogsAfter | ForEach-Object { [int]$_.id })
  if ($idsAfter -notcontains $createId) {
    throw "Audit record disappeared unexpectedly (not append-only)"
  }
  Write-Host "  append-only check passed"

  Write-Host "[8/8] PASS: P1-3 audit trail works"
}
finally {
  if ($ruleId -gt 0) {
    try {
      $disableBody = @{ enabled = $false } | ConvertTo-Json -Compress
      Invoke-RestMethod "$ApiBase/api/alarm_rules/$ruleId/enabled" -Headers $headers -Method Patch -ContentType "application/json" -Body $disableBody | Out-Null
    } catch { }
  }
}
