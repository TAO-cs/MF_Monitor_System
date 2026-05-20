Param(
  [string]$EnvFile = ".env.dev.ha.mqtt",
  [string]$GatewayBase = "https://127.0.0.1",
  [int]$PollSeconds = 45
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

$authHeaders = @{ Authorization = "Bearer $apiKey" }

function As-Array {
  param([object]$Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Array]) { return $Value }
  return @($Value)
}

function Get-LabeledMetricValue {
  param(
    [string]$Metrics,
    [string]$MetricName,
    [hashtable]$Labels
  )

  $labelParts = @()
  foreach ($k in ($Labels.Keys | Sort-Object)) {
    $v = [string]$Labels[$k]
    $labelParts += "$k=`"$v`""
  }
  $labelText = [string]::Join(",", $labelParts)
  $pattern = '(?m)^' + [regex]::Escape($MetricName) + '\{' + [regex]::Escape($labelText) + '\}\s+([0-9.]+)$'
  $m = [regex]::Match($Metrics, $pattern)
  if (-not $m.Success) { return $null }
  return [double]$m.Groups[1].Value
}

function Get-MetricValue {
  param(
    [string]$Metrics,
    [string]$MetricName
  )
  $pattern = '(?m)^' + [regex]::Escape($MetricName) + '\s+([0-9.]+)$'
  $m = [regex]::Match($Metrics, $pattern)
  if (-not $m.Success) { return $null }
  return [double]$m.Groups[1].Value
}

function Get-SysTopicValue {
  param(
    [string]$ContainerName,
    [string]$Topic,
    [int]$WaitSeconds = 8
  )

  $raw = docker exec $ContainerName sh -c "mosquitto_sub -h 127.0.0.1 -p 1883 -t '$Topic' -C 1 -W $WaitSeconds" 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  $value = (($raw | Out-String).Trim())
  if ([string]::IsNullOrWhiteSpace($value)) { return $null }
  return $value
}

function Assert-IsNumeric {
  param(
    [string]$Name,
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$Name is empty"
  }
  if ($Value -notmatch '^\d+(\.\d+)?$') {
    throw "$Name is not numeric: $Value"
  }
}

function Publish-JsonViaProxy {
  param(
    [string]$Topic,
    [hashtable]$Payload,
    [string]$RunnerContainer = "mf_mqtt_2"
  )

  $json = $Payload | ConvertTo-Json -Compress -Depth 20
  $payloadB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
  $cmd = "echo '$payloadB64' | base64 -d | mosquitto_pub -h mqtt -p 1883 -t '$Topic' -l -q 1"
  docker exec $RunnerContainer sh -c $cmd | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "mosquitto_pub failed via $RunnerContainer"
  }
}

function Get-ClassificationCount {
  param(
    [string]$ApiBase,
    [hashtable]$Headers,
    [string]$AiboxId,
    [string]$CamId,
    [string]$DisasterId
  )

  $url = "$ApiBase/api/classification?paginate=true&page=1&page_size=50&aibox_id=$AiboxId&cam_id=$CamId"
  $resp = Invoke-RestMethod $url -Headers $Headers -Method Get
  $items = @()

  if ($resp -is [System.Array]) {
    $items = @($resp)
  } elseif ($resp.PSObject.Properties.Name -contains 'items') {
    $items = @(As-Array $resp.items)
  } else {
    $items = @(As-Array $resp)
  }
  return @($items | Where-Object { $_.disaster_id -eq $DisasterId }).Count
}

Write-Host "[1/9] Check required containers"
$required = @('mf_mysql','mf_nginx','mf_backend_api_1','mf_backend_api_2','mf_backend_worker','mf_mqtt','mf_mqtt_1','mf_mqtt_2')
foreach ($c in $required) {
  $running = (docker inspect -f '{{.State.Running}}' $c 2>$null)
  if ($LASTEXITCODE -ne 0 -or $running.Trim() -ne 'true') {
    throw "container not running: $c"
  }
}
Write-Host "  containers ok"

Write-Host "[2/9] Check health and role split"
$gatewayCode = (& curl.exe -k -s -o NUL -w "%{http_code}" "$GatewayBase/health")
if ([int]$gatewayCode -ne 200) {
  throw "gateway /health expected 200, got $gatewayCode"
}

$api1 = Invoke-RestMethod "http://127.0.0.1:18001/health" -Method Get
$api2 = Invoke-RestMethod "http://127.0.0.1:18002/health" -Method Get
$worker = Invoke-RestMethod "http://127.0.0.1:18003/health" -Method Get

if ($api1.instance_id -ne 'backend-api-1' -or [bool]$api1.ingestion_enabled) {
  throw "backend_api_1 role mismatch"
}
if ($api2.instance_id -ne 'backend-api-2' -or [bool]$api2.ingestion_enabled) {
  throw "backend_api_2 role mismatch"
}
if ($worker.instance_id -ne 'backend-worker' -or -not [bool]$worker.ingestion_enabled) {
  throw "backend_worker role mismatch"
}
Write-Host "  health and role split ok"

Write-Host "[3/9] Snapshot worker MQTT metrics"
$workerMetricsBefore = (Invoke-WebRequest "http://127.0.0.1:18003/metrics" -UseBasicParsing).Content
$beforeClsOk = Get-LabeledMetricValue -Metrics $workerMetricsBefore -MetricName 'mf_mqtt_messages_total' -Labels @{ result = 'ok'; topic_type = 'classification' }
if ($null -eq $beforeClsOk) { $beforeClsOk = 0 }
Write-Host "  baseline classification_ok=$beforeClsOk"

$tag = Get-Date -Format "yyyyMMdd_HHmmss"
$aiboxId = "P22_$tag"
$camId = "CAM_$tag"
$topic = "disaster_monitoring/$aiboxId/classification"
$iso = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$disaster1 = "p22_cls_${tag}_1"
$payload1 = @{
  disaster_id = $disaster1
  disaster_type = "flood"
  timestamp = $iso
  confidence = 0.97
  aibox_id = $aiboxId
  cam_id = $camId
  image_path = "https://storage.server/data/images/p22_1.jpg"
}

Write-Host "[4/9] Publish via proxy and verify write path"
Publish-JsonViaProxy -Topic $topic -Payload $payload1 -RunnerContainer "mf_mqtt_2"

$found1 = $false
for ($i = 0; $i -lt 20; $i++) {
  $cnt = Get-ClassificationCount -ApiBase "http://127.0.0.1:18001" -Headers $authHeaders -AiboxId $aiboxId -CamId $camId -DisasterId $disaster1
  if ($cnt -ge 1) {
    $found1 = $true
    break
  }
  Start-Sleep -Seconds 1
}
if (-not $found1) {
  throw "classification record not found after proxy publish: $disaster1"
}
Write-Host "  publish/write path ok"

Write-Host "[5/9] Check broker monitoring topics on primary"
$priConnected = Get-SysTopicValue -ContainerName "mf_mqtt_1" -Topic '$SYS/broker/clients/connected'
$priReceived = Get-SysTopicValue -ContainerName "mf_mqtt_1" -Topic '$SYS/broker/messages/received'
$priStored = Get-SysTopicValue -ContainerName "mf_mqtt_1" -Topic '$SYS/broker/messages/stored'

Assert-IsNumeric -Name "primary.clients.connected" -Value $priConnected
Assert-IsNumeric -Name "primary.messages.received" -Value $priReceived
Assert-IsNumeric -Name "primary.messages.stored" -Value $priStored
Write-Host "  primary metrics: connected=$priConnected, received=$priReceived, stored=$priStored"

Write-Host "[6/9] Failover drill: stop primary broker"
$primaryStopped = $false
try {
  docker stop mf_mqtt_1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "failed to stop mf_mqtt_1"
  }
  $primaryStopped = $true

  $recovered = $false
  for ($i = 0; $i -lt $PollSeconds; $i++) {
    Start-Sleep -Seconds 1

    $workerMetrics = (Invoke-WebRequest "http://127.0.0.1:18003/metrics" -UseBasicParsing).Content
    $workerConn = Get-MetricValue -Metrics $workerMetrics -MetricName 'mf_mqtt_connected'
    $secConnected = Get-SysTopicValue -ContainerName "mf_mqtt_2" -Topic '$SYS/broker/clients/connected' -WaitSeconds 3

    if ($null -ne $workerConn -and $workerConn -ge 1 -and $null -ne $secConnected -and $secConnected -match '^\d+(\.\d+)?$' -and [double]$secConnected -ge 1) {
      $recovered = $true
      break
    }
  }

  if (-not $recovered) {
    throw "worker did not reconnect through proxy after primary stop"
  }
  Write-Host "  failover reconnection ok"

  Write-Host "[7/9] Publish during failover and verify write path"
  $disaster2 = "p22_cls_${tag}_2"
  $payload2 = @{
    disaster_id = $disaster2
    disaster_type = "flood"
    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    confidence = 0.98
    aibox_id = $aiboxId
    cam_id = $camId
    image_path = "https://storage.server/data/images/p22_2.jpg"
  }

  Publish-JsonViaProxy -Topic $topic -Payload $payload2 -RunnerContainer "mf_mqtt_2"

  $found2 = $false
  for ($i = 0; $i -lt 20; $i++) {
    $cnt = Get-ClassificationCount -ApiBase "http://127.0.0.1:18001" -Headers $authHeaders -AiboxId $aiboxId -CamId $camId -DisasterId $disaster2
    if ($cnt -ge 1) {
      $found2 = $true
      break
    }
    Start-Sleep -Seconds 1
  }
  if (-not $found2) {
    throw "classification record not found during failover: $disaster2"
  }
  Write-Host "  write path during failover ok"

  Write-Host "[8/9] Check monitoring topics on secondary + throughput increment"
  $workerMetricsAfter = (Invoke-WebRequest "http://127.0.0.1:18003/metrics" -UseBasicParsing).Content
  $afterClsOk = Get-LabeledMetricValue -Metrics $workerMetricsAfter -MetricName 'mf_mqtt_messages_total' -Labels @{ result = 'ok'; topic_type = 'classification' }
  if ($null -eq $afterClsOk) {
    throw "missing worker metric: mf_mqtt_messages_total{result=ok,topic_type=classification}"
  }
  if ($afterClsOk -le $beforeClsOk) {
    throw "classification throughput metric did not increase: before=$beforeClsOk after=$afterClsOk"
  }

  $secConnected2 = Get-SysTopicValue -ContainerName "mf_mqtt_2" -Topic '$SYS/broker/clients/connected'
  $secReceived2 = Get-SysTopicValue -ContainerName "mf_mqtt_2" -Topic '$SYS/broker/messages/received'
  $secStored2 = Get-SysTopicValue -ContainerName "mf_mqtt_2" -Topic '$SYS/broker/messages/stored'

  Assert-IsNumeric -Name "secondary.clients.connected" -Value $secConnected2
  Assert-IsNumeric -Name "secondary.messages.received" -Value $secReceived2
  Assert-IsNumeric -Name "secondary.messages.stored" -Value $secStored2

  Write-Host "  secondary metrics: connected=$secConnected2, received=$secReceived2, stored=$secStored2"
  Write-Host "  worker throughput metric: before=$beforeClsOk, after=$afterClsOk"
}
finally {
  if ($primaryStopped) {
    docker start mf_mqtt_1 | Out-Null
    Start-Sleep -Seconds 2
  }
}

Write-Host "[9/9] PASS: P2-2 MQTT cluster baseline works"
