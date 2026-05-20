Param(
  [string]$EnvFile = ".env.dev",
  [string]$ApiBase = "http://127.0.0.1:8000",
  [int]$WaitSeconds = 40
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $EnvFile)) { throw "Env file not found: $EnvFile" }

function As-Array {
  param([object]$Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Array]) { return $Value }
  return @($Value)
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
$aiboxId = "P12_$tag"
$camId = "CAM_$tag"
$ruleCode = "p1_notify_cls_$tag"
$channelCode = "p1_webhook_$tag"
$ruleId = 0
$channelId = 0

$outDir = "test\tmp"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outFile = Join-Path $outDir "p1_2_notify_$tag.ndjson"
if (Test-Path $outFile) { Remove-Item $outFile -Force }

$port = 18700 + (Get-Random -Minimum 1 -Maximum 200)
$mockProc = $null

try {
  Write-Host "[1/9] Start mock webhook server"
  $py = ".\venv_MFSystem\Scripts\python.exe"
  if (-not (Test-Path $py)) {
    throw "Python not found in venv: $py"
  }
  $args = @("test\mock_webhook_server.py", "--host", "127.0.0.1", "--port", "$port", "--out", $outFile, "--fail-first", "1")
  $mockProc = Start-Process -FilePath $py -ArgumentList $args -PassThru -WindowStyle Hidden

  $ok = $false
  for ($i=0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    try {
      $health = Invoke-RestMethod "http://127.0.0.1:$port/health" -Method Get
      if ($health.ok -eq $true) { $ok = $true; break }
    } catch { }
  }
  if (-not $ok) { throw "Mock webhook server did not become healthy on port $port" }
  Write-Host "  mock webhook ready: http://127.0.0.1:$port/notify"

  Write-Host "[2/9] Create notification channel (enabled, fail-first retry test)"
  $chBody = @{
    channel_code = $channelCode
    name = "P1-2 webhook channel $tag"
    channel_type = "webhook"
    enabled = $true
    retry_max = 3
    retry_interval_seconds = 2
    timeout_seconds = 2
    config_json = @{
      url = "http://127.0.0.1:$port/notify"
      headers = @{ "X-P1-2" = "verify" }
    }
  } | ConvertTo-Json -Depth 8 -Compress
  $channel = Invoke-RestMethod "$ApiBase/api/notification_channels" -Headers $headers -Method Post -ContentType "application/json" -Body $chBody
  $channelId = [int]$channel.id
  Write-Host "  created channel id=$channelId, code=$($channel.channel_code)"

  Write-Host "[3/9] Create dedicated alarm rule"
  $ruleBody = @{
    rule_code = $ruleCode
    name = "P1-2 notification rule $tag"
    event_type = "classification"
    severity = "high"
    enabled = $true
    cooldown_seconds = 60
    condition_json = @{ disaster_type = "mudslide"; min_confidence = 0.95 }
  } | ConvertTo-Json -Compress
  $rule = Invoke-RestMethod "$ApiBase/api/alarm_rules" -Headers $headers -Method Post -ContentType "application/json" -Body $ruleBody
  $ruleId = [int]$rule.id
  Write-Host "  created rule id=$ruleId, code=$($rule.rule_code)"

  Write-Host "[4/9] Publish classification to trigger alarm"
  $iso = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $disasterId = "p12_cls_" + (Get-Date -Format "yyyyMMddHHmmss")
  $clsPayload = @{
    disaster_id = $disasterId
    disaster_type = "mudslide"
    timestamp = $iso
    confidence = 0.99
    aibox_id = $aiboxId
    cam_id = $camId
    image_path = "https://storage.server/data/images/p1_2_notify.jpg"
  } | ConvertTo-Json -Compress

  $null = $clsPayload | docker exec -i mf_mqtt mosquitto_pub -h 127.0.0.1 -p 1883 -t "disaster_monitoring/$aiboxId/classification" -q 1 -s
  if ($LASTEXITCODE -ne 0) { throw "Failed to publish classification payload" }

  Write-Host "[5/9] Poll alarm generation"
  $alarm = $null
  for ($i=0; $i -lt $WaitSeconds; $i++) {
    $alarmsRaw = Invoke-RestMethod "$ApiBase/api/alarms?rule_code=$ruleCode&aibox_id=$aiboxId&cam_id=$camId" -Headers $headers -Method Get
    $alarms = @(As-Array $alarmsRaw | Where-Object { $_ -ne $null -and $_.PSObject.Properties.Name -contains "id" })
    if ($alarms.Count -gt 0) {
      $alarm = $alarms | Sort-Object { [int]$_.id } -Descending | Select-Object -First 1
      break
    }
    Start-Sleep -Seconds 1
  }
  if ($null -eq $alarm) { throw "No alarm generated for rule $ruleCode" }
  $alarmId = [int]$alarm.id
  Write-Host "  alarm generated id=$alarmId"

  Write-Host "[6/9] Poll alarm notification status (target sent + channel has retry)"
  $targetNotify = $null
  $retriedNotify = $null
  for ($i=0; $i -lt $WaitSeconds; $i++) {
    $nrTarget = Invoke-RestMethod "$ApiBase/api/alarm_notifications?alarm_id=$alarmId&channel_code=$channelCode" -Headers $headers -Method Get
    $arrTarget = @(As-Array $nrTarget | Where-Object { $_ -ne $null -and $_.PSObject.Properties.Name -contains "id" })
    if ($arrTarget.Count -gt 0) {
      $targetNotify = $arrTarget | Sort-Object { [int]$_.id } -Descending | Select-Object -First 1
    }

    $nrChannel = Invoke-RestMethod "$ApiBase/api/alarm_notifications?channel_code=$channelCode" -Headers $headers -Method Get
    $arrChannel = @(As-Array $nrChannel | Where-Object { $_ -ne $null -and $_.PSObject.Properties.Name -contains "id" })
    $retriedCandidates = @($arrChannel | Where-Object { $_.status -eq "sent" -and [int]$_.attempts -ge 2 })
    if ($retriedCandidates.Count -gt 0) {
      $retriedNotify = $retriedCandidates | Sort-Object { [int]$_.id } -Descending | Select-Object -First 1
    }

    if ($targetNotify -and $targetNotify.status -eq "sent" -and $retriedNotify) {
      break
    }

    Start-Sleep -Seconds 1
  }

  if ($null -eq $targetNotify) {
    throw "No alarm_notification record generated for target alarm_id=$alarmId"
  }

  if ($targetNotify.status -ne "sent") {
    throw "Expected target notification status=sent, got $($targetNotify.status)"
  }

  if ($null -eq $retriedNotify) {
    throw "Expected at least one sent notification with attempts >= 2 on channel $channelCode"
  }

  Write-Host "  target sent attempts=$($targetNotify.attempts); retry proof alarm_id=$($retriedNotify.alarm_id), attempts=$($retriedNotify.attempts)"

  Write-Host "[7/9] Verify mock receiver file"
  if (-not (Test-Path $outFile)) {
    throw "Mock output file not found: $outFile"
  }
  $lines = Get-Content $outFile | Where-Object { $_.Trim().Length -gt 0 }
  if ($lines.Count -lt 2) {
    throw "Expected at least 2 webhook hits (fail+retry), got $($lines.Count)"
  }
  Write-Host "  webhook hits=$($lines.Count)"

  Write-Host "[8/9] Verify metrics"
  $m = (Invoke-WebRequest "$ApiBase/metrics" -UseBasicParsing).Content
  if ($m -notmatch 'mf_notify_attempts_total\{channel_type="webhook",result="failed"\}') {
    throw "Missing failed notify metric"
  }
  if ($m -notmatch 'mf_notify_attempts_total\{channel_type="webhook",result="sent"\}') {
    throw "Missing sent notify metric"
  }
  Write-Host "  notify metrics present"

  Write-Host "[9/9] PASS: P1-2 notification channel works (webhook + retry)"
}
finally {
  if ($ruleId -gt 0) {
    try {
      $disableRule = @{ enabled = $false } | ConvertTo-Json -Compress
      Invoke-RestMethod "$ApiBase/api/alarm_rules/$ruleId/enabled" -Headers $headers -Method Patch -ContentType "application/json" -Body $disableRule | Out-Null
    } catch { }
  }

  if ($channelId -gt 0) {
    try {
      $disableCh = @{ enabled = $false } | ConvertTo-Json -Compress
      Invoke-RestMethod "$ApiBase/api/notification_channels/$channelId/enabled" -Headers $headers -Method Patch -ContentType "application/json" -Body $disableCh | Out-Null
    } catch { }
  }

  if ($mockProc -and -not $mockProc.HasExited) {
    try {
      Stop-Process -Id $mockProc.Id -Force
    } catch { }
  }
}

