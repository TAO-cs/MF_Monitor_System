Param(
  [string]$EnvFile = ".env.dev.ha.mqtt.dbha"
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
$rootPassword = $envMap['MYSQL_ROOT_PASSWORD']

if (-not $apiKey) { throw "API_KEY missing in $EnvFile" }
if (-not $rootPassword) { throw "MYSQL_ROOT_PASSWORD missing in $EnvFile" }

$authHeaders = @{ Authorization = "Bearer $apiKey" }
$bt = [char]96
$tsCol = "$bt" + "timestamp" + "$bt"

function Query-SingleValue {
  param(
    [string]$ContainerName,
    [string]$Sql,
    [string]$Database = ""
  )

  $args = @("exec", $ContainerName, "mysql", "-uroot", "-p$rootPassword", "-N", "-s")
  if (-not [string]::IsNullOrWhiteSpace($Database)) {
    $args += @("-D", $Database)
  }
  $args += @("-e", $Sql)

  $raw = & docker @args
  if ($LASTEXITCODE -ne 0) {
    throw "Query failed on $ContainerName. SQL: $Sql"
  }
  return (($raw | Out-String).Trim())
}

function Exec-Sql {
  param(
    [string]$ContainerName,
    [string]$Sql,
    [string]$Database = ""
  )

  $args = @("exec", $ContainerName, "mysql", "-uroot", "-p$rootPassword")
  if (-not [string]::IsNullOrWhiteSpace($Database)) {
    $args += @("-D", $Database)
  }
  $args += @("-e", $Sql)

  & docker @args | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "SQL execution failed on $ContainerName. SQL: $Sql"
  }
}

Write-Host "[1/7] Check required containers"
$required = @('mf_mysql','mf_mysql_replica','mf_mqtt','mf_nginx','mf_backend_api_1','mf_backend_api_2','mf_backend_worker')
foreach ($c in $required) {
  $running = (docker inspect -f '{{.State.Running}}' $c 2>$null)
  if ($LASTEXITCODE -ne 0 -or $running.Trim() -ne 'true') {
    throw "container not running: $c"
  }
}
Write-Host "  containers ok"

Write-Host "[2/7] Check backend gateway health"
$gatewayCode = (& curl.exe -k -s -o NUL -w "%{http_code}" "https://127.0.0.1/health")
if ([int]$gatewayCode -ne 200) {
  throw "gateway /health expected 200, got $gatewayCode"
}
$apiCode = (& curl.exe -k -s -o NUL -w "%{http_code}" -H "Authorization: Bearer $apiKey" "https://127.0.0.1/api/device_status")
if ([int]$apiCode -ne 200) {
  throw "gateway /api/device_status expected 200, got $apiCode"
}
Write-Host "  gateway ok"

Write-Host "[3/7] Check replica state"
$ioState = Query-SingleValue -ContainerName "mf_mysql_replica" -Sql "SELECT IFNULL((SELECT SERVICE_STATE FROM performance_schema.replication_connection_status LIMIT 1),'OFF');"
$sqlState = Query-SingleValue -ContainerName "mf_mysql_replica" -Sql "SELECT IFNULL((SELECT SERVICE_STATE FROM performance_schema.replication_applier_status LIMIT 1),'OFF');"
if ($ioState -ne 'ON' -or $sqlState -ne 'ON') {
  throw "replication threads not ON: io=$ioState sql=$sqlState"
}

$roLine = Query-SingleValue -ContainerName "mf_mysql_replica" -Sql "SELECT CONCAT(@@GLOBAL.read_only, ',', @@GLOBAL.super_read_only);"
if ($roLine -ne '1,1') {
  throw "replica read-only mismatch: $roLine"
}
Write-Host "  replica state ok (io=$ioState, sql=$sqlState, read_only=$roLine)"

$tag = Get-Date -Format "yyyyMMdd_HHmmss"
$marker = "p23_marker_$tag"

Write-Host "[4/7] Write marker on primary"
$insertSql = "INSERT INTO disaster_data (disaster_id, aibox_id, cam_id, disaster_type, $tsCol, confidence, image_path) VALUES ('$marker', 'P23HA', 'CAMHA', 'flood', NOW(), 0.996, 'https://storage.server/data/images/p23_marker.jpg');"
Exec-Sql -ContainerName "mf_mysql" -Database "mf_monitor" -Sql $insertSql

Write-Host "[5/7] Verify marker replicated to replica"
$replicated = $false
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Seconds 1
  $count = Query-SingleValue -ContainerName "mf_mysql_replica" -Database "mf_monitor" -Sql "SELECT COUNT(*) FROM disaster_data WHERE disaster_id='$marker';"
  if ([int]$count -ge 1) {
    $replicated = $true
    break
  }
}
if (-not $replicated) {
  throw "marker not replicated to replica: $marker"
}
Write-Host "  replication path ok (marker=$marker)"

Write-Host "[6/7] Check replica endpoint direct query"
$replicaCount = Query-SingleValue -ContainerName "mf_mysql_replica" -Database "mf_monitor" -Sql "SELECT COUNT(*) FROM disaster_data;"
if ([int]$replicaCount -le 0) {
  throw "replica data count invalid: $replicaCount"
}
Write-Host "  replica query ok (disaster_data count=$replicaCount)"

Write-Host "[7/7] PASS: P2-3 MySQL HA baseline works"
