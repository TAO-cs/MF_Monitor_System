Param(
  [ValidateSet("dev", "test", "prod")]
  [string]$Env = "dev",
  [string]$EnvFile = ""
)

$ErrorActionPreference = "Stop"
. .\scripts\p2_6_release_utils.ps1

if (-not $EnvFile) {
  $candidate = ".env.$Env"
  if (Test-Path $candidate) {
    $EnvFile = $candidate
  } else {
    $EnvFile = ".env"
  }
}

if (-not (Test-Path $EnvFile)) {
  throw "Env file not found: $EnvFile"
}

function Wait-ContainerHealthy {
  param(
    [string]$ContainerName,
    [int]$TimeoutSec = 180
  )

  $start = Get-Date
  while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSec) {
    $state = (docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $ContainerName 2>$null)
    if ($LASTEXITCODE -eq 0 -and ($state.Trim() -eq 'healthy' -or $state.Trim() -eq 'running')) {
      return
    }
    Start-Sleep -Seconds 2
  }

  throw "Container not healthy in time: $ContainerName"
}

function Invoke-ContainerSql {
  param(
    [string]$ContainerName,
    [string]$User,
    [string]$Password = "",
    [string]$Sql,
    [string]$Database = ""
  )

  $args = @("exec", $ContainerName, "mysql", "-u$User", "--default-character-set=utf8mb4")
  if (-not [string]::IsNullOrWhiteSpace($Password)) {
    $args += "-p$Password"
  }
  if (-not [string]::IsNullOrWhiteSpace($Database)) {
    $args += @("-D", $Database)
  }
  $args += @("-e", $Sql)

  $output = & docker @args
  if ($LASTEXITCODE -ne 0) {
    throw "SQL execution failed on $ContainerName. SQL: $Sql"
  }

  return $output
}

function Query-SingleValue {
  param(
    [string]$ContainerName,
    [string]$User,
    [string]$Password = "",
    [string]$Sql,
    [string]$Database = ""
  )

  $args = @("exec", $ContainerName, "mysql", "-u$User", "-N", "-s", "--default-character-set=utf8mb4")
  if (-not [string]::IsNullOrWhiteSpace($Password)) {
    $args += "-p$Password"
  }
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

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check_env.ps1 -EnvFile $EnvFile -Mode compose

$envPath = (Resolve-Path $EnvFile).Path
$dbHaEnv = "$envPath.ha.mqtt.dbha"

$lines = Get-Content $envPath
$map = @{}
foreach ($line in $lines) {
  if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
  $parts = $line.Split('=', 2)
  $map[$parts[0].Trim()] = $parts[1]
}

$map['DB_HOST'] = 'mysql'
$map['DB_PORT'] = '3306'
$map['MQTT_BROKER_HOST'] = 'mqtt'
$map['MQTT_BROKER_PORT'] = '1883'
if (-not $map.ContainsKey('RELEASE_VERSION_STABLE') -or [string]::IsNullOrWhiteSpace($map['RELEASE_VERSION_STABLE'])) {
  $map['RELEASE_VERSION_STABLE'] = "$Env-stable"
}
if (-not $map.ContainsKey('RELEASE_VERSION_CANARY') -or [string]::IsNullOrWhiteSpace($map['RELEASE_VERSION_CANARY'])) {
  $map['RELEASE_VERSION_CANARY'] = "$Env-canary"
}
if (-not $map.ContainsKey('RELEASE_VERSION_WORKER') -or [string]::IsNullOrWhiteSpace($map['RELEASE_VERSION_WORKER'])) {
  $map['RELEASE_VERSION_WORKER'] = "$Env-worker"
}
if (-not $map.ContainsKey('RELEASE_VERSION_PREVIOUS_STABLE')) {
  $map['RELEASE_VERSION_PREVIOUS_STABLE'] = ''
}

if (-not $map.ContainsKey('MYSQL_REPL_USER') -or [string]::IsNullOrWhiteSpace($map['MYSQL_REPL_USER'])) {
  $map['MYSQL_REPL_USER'] = 'replicator'
}
if (-not $map.ContainsKey('MYSQL_REPL_PASSWORD') -or [string]::IsNullOrWhiteSpace($map['MYSQL_REPL_PASSWORD'])) {
  $map['MYSQL_REPL_PASSWORD'] = 'repl123'
}

$out = @()
foreach ($line in $lines) {
  if ($line -match '^\s*#' -or $line -notmatch '=') {
    $out += $line
    continue
  }

  $parts = $line.Split('=', 2)
  $key = $parts[0].Trim()
  if ($map.ContainsKey($key)) {
    $out += "$key=$($map[$key])"
    $map.Remove($key) | Out-Null
  } else {
    $out += $line
  }
}

foreach ($k in $map.Keys) {
  $out += "$k=$($map[$k])"
}

Set-Content -Path $dbHaEnv -Value $out -Encoding UTF8

if (-not (Test-Path "nginx/certs/server.crt") -or -not (Test-Path "nginx/certs/server.key")) {
  Write-Host "Nginx cert not found, generating self-signed cert..."
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\gen_nginx_cert.ps1
}

$env:HA_ENV_FILE = $dbHaEnv
$env:APP_ENV = $Env
$env:BACKEND_BASE_IMAGE = Resolve-P26BackendBaseImage

docker compose --env-file $dbHaEnv -f docker-compose.yml -f docker-compose.p2-ha.yml -f docker-compose.p2-mqtt.yml -f docker-compose.p2-mysql-ha.yml up -d --build mysql mysql_replica mqtt_primary mqtt_secondary mqtt backend_api_1 backend_api_2 backend_worker nginx
if ($LASTEXITCODE -ne 0) {
  throw "Failed to start P2-3 MySQL HA stack."
}

$rootPassword = ((Get-Content $dbHaEnv | Select-String '^MYSQL_ROOT_PASSWORD=' | ForEach-Object { $_.Line -replace '^MYSQL_ROOT_PASSWORD=', '' } | Select-Object -First 1) | Out-String).Trim()
$replUser = ((Get-Content $dbHaEnv | Select-String '^MYSQL_REPL_USER=' | ForEach-Object { $_.Line -replace '^MYSQL_REPL_USER=', '' } | Select-Object -First 1) | Out-String).Trim()
$replPass = ((Get-Content $dbHaEnv | Select-String '^MYSQL_REPL_PASSWORD=' | ForEach-Object { $_.Line -replace '^MYSQL_REPL_PASSWORD=', '' } | Select-Object -First 1) | Out-String).Trim()
$dbName = ((Get-Content $dbHaEnv | Select-String '^DB_NAME=' | ForEach-Object { $_.Line -replace '^DB_NAME=', '' } | Select-Object -First 1) | Out-String).Trim()
$dbUser = ((Get-Content $dbHaEnv | Select-String '^DB_USER=' | ForEach-Object { $_.Line -replace '^DB_USER=', '' } | Select-Object -First 1) | Out-String).Trim()
$dbPass = ((Get-Content $dbHaEnv | Select-String '^DB_PASSWORD=' | ForEach-Object { $_.Line -replace '^DB_PASSWORD=', '' } | Select-Object -First 1) | Out-String).Trim()

if ([string]::IsNullOrWhiteSpace($rootPassword)) { throw "MYSQL_ROOT_PASSWORD missing in runtime env" }
if ([string]::IsNullOrWhiteSpace($replUser)) { throw "MYSQL_REPL_USER missing in runtime env" }
if ([string]::IsNullOrWhiteSpace($replPass)) { throw "MYSQL_REPL_PASSWORD missing in runtime env" }
if ([string]::IsNullOrWhiteSpace($dbName)) { throw "DB_NAME missing in runtime env" }
if ([string]::IsNullOrWhiteSpace($dbUser)) { throw "DB_USER missing in runtime env" }
if ([string]::IsNullOrWhiteSpace($dbPass)) { throw "DB_PASSWORD missing in runtime env" }

Write-Host "Waiting MySQL containers healthy..."
Wait-ContainerHealthy -ContainerName "mf_mysql"
Wait-ContainerHealthy -ContainerName "mf_mysql_replica"

# If replica was initialized with empty root password due previous bad startup, repair it.
$replicaAuthOk = $false
try {
  Query-SingleValue -ContainerName "mf_mysql_replica" -User "root" -Password $rootPassword -Sql "SELECT 1;" | Out-Null
  $replicaAuthOk = $true
} catch {
  $replicaAuthOk = $false
}

if (-not $replicaAuthOk) {
  Write-Warning "Replica root auth with configured password failed, trying empty password recovery..."
  Query-SingleValue -ContainerName "mf_mysql_replica" -User "root" -Password "" -Sql "SELECT 1;" | Out-Null
  Invoke-ContainerSql -ContainerName "mf_mysql_replica" -User "root" -Password "" -Sql "ALTER USER IF EXISTS 'root'@'localhost' IDENTIFIED BY '$rootPassword'; ALTER USER IF EXISTS 'root'@'%' IDENTIFIED BY '$rootPassword'; FLUSH PRIVILEGES;"
}

$primaryRootOk = $false
try {
  Query-SingleValue -ContainerName "mf_mysql" -User "root" -Password $rootPassword -Sql "SELECT 1;" | Out-Null
  $primaryRootOk = $true
} catch {
  $primaryRootOk = $false
}

if ($primaryRootOk) {
  Write-Host "Configuring replication user on primary..."
  Invoke-ContainerSql -ContainerName "mf_mysql" -User "root" -Password $rootPassword -Sql "CREATE USER IF NOT EXISTS '$replUser'@'%' IDENTIFIED BY '$replPass'; GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '$replUser'@'%'; FLUSH PRIVILEGES;"
} else {
  Write-Warning "Primary root auth failed, skip replication user creation and verify existing account..."
  try {
    Query-SingleValue -ContainerName "mf_mysql" -User $replUser -Password $replPass -Sql "SELECT 1;" | Out-Null
  } catch {
    throw "Primary root auth failed and replication account check failed. Fix MYSQL_ROOT_PASSWORD or create $replUser manually on primary."
  }
}

if ($primaryRootOk) {
  $dumpUser = "root"
  $dumpPass = $rootPassword
} else {
  $dumpUser = $dbUser
  $dumpPass = $dbPass
  try {
    Query-SingleValue -ContainerName "mf_mysql" -User $dumpUser -Password $dumpPass -Sql "SELECT 1;" | Out-Null
  } catch {
    throw "DB_USER auth failed and root auth unavailable on primary, cannot create snapshot dump."
  }
}

Write-Host "Syncing replica from primary snapshot..."
$dumpFile = Join-Path (Get-Location) ".tmp_p2_3_seed.sql"
$bt = [char]96
if (Test-Path $dumpFile) {
  Remove-Item -LiteralPath $dumpFile -Force
}

try {
  $primaryDumpPath = "/tmp/p2_3_seed.sql"
  $replicaDumpPath = "/tmp/p2_3_seed.sql"

  $dumpCmd = "mysqldump -u$dumpUser -p$dumpPass --single-transaction --quick --skip-lock-tables --no-tablespaces --set-gtid-purged=ON --routines --events --triggers --databases $dbName > $primaryDumpPath"
  $dumpOk = $false
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    & docker exec mf_mysql sh -lc $dumpCmd
    if ($LASTEXITCODE -eq 0) {
      $dumpOk = $true
      break
    }
    Start-Sleep -Seconds 2
  }
  if (-not $dumpOk) {
    throw "Failed to create primary dump for $dbName."
  }

  & docker cp "mf_mysql:$primaryDumpPath" $dumpFile
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dumpFile) -or (Get-Item $dumpFile).Length -le 0) {
    throw "Failed to create primary dump for $dbName."
  }

  Invoke-ContainerSql -ContainerName "mf_mysql_replica" -User "root" -Password $rootPassword -Sql "STOP REPLICA;"
  Invoke-ContainerSql -ContainerName "mf_mysql_replica" -User "root" -Password $rootPassword -Sql "RESET REPLICA ALL;"
  Invoke-ContainerSql -ContainerName "mf_mysql_replica" -User "root" -Password $rootPassword -Sql "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"
  Invoke-ContainerSql -ContainerName "mf_mysql_replica" -User "root" -Password $rootPassword -Sql "RESET MASTER;"
  Invoke-ContainerSql -ContainerName "mf_mysql_replica" -User "root" -Password $rootPassword -Sql "DROP DATABASE IF EXISTS $bt$dbName$bt;"

  & docker cp $dumpFile "mf_mysql_replica:$replicaDumpPath"
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to copy primary snapshot into replica."
  }

  $restoreCmd = "mysql -uroot -p$rootPassword --default-character-set=utf8mb4 < $replicaDumpPath"
  & docker exec mf_mysql_replica sh -lc $restoreCmd
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to load primary snapshot into replica."
  }

  & docker exec mf_mysql sh -lc "rm -f $primaryDumpPath" | Out-Null
  & docker exec mf_mysql_replica sh -lc "rm -f $replicaDumpPath" | Out-Null
}
finally {
  if (Test-Path $dumpFile) {
    Remove-Item -LiteralPath $dumpFile -Force
  }
}

Write-Host "Configuring replica source..."
Invoke-ContainerSql -ContainerName "mf_mysql_replica" -User "root" -Password $rootPassword -Sql "CHANGE REPLICATION SOURCE TO SOURCE_HOST='mysql', SOURCE_PORT=3306, SOURCE_USER='$replUser', SOURCE_PASSWORD='$replPass', SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1;"
Invoke-ContainerSql -ContainerName "mf_mysql_replica" -User "root" -Password $rootPassword -Sql "START REPLICA;"

Write-Host "Waiting replication ready..."
$ok = $false
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Seconds 2

  $ioState = Query-SingleValue -ContainerName "mf_mysql_replica" -User "root" -Password $rootPassword -Sql "SELECT IFNULL((SELECT SERVICE_STATE FROM performance_schema.replication_connection_status LIMIT 1),'OFF');"
  $sqlState = Query-SingleValue -ContainerName "mf_mysql_replica" -User "root" -Password $rootPassword -Sql "SELECT IFNULL((SELECT SERVICE_STATE FROM performance_schema.replication_applier_status LIMIT 1),'OFF');"

  if ($ioState -eq 'ON' -and $sqlState -eq 'ON') {
    $ok = $true
    break
  }
}

if (-not $ok) {
  $status = Invoke-ContainerSql -ContainerName "mf_mysql_replica" -User "root" -Password $rootPassword -Sql "SHOW REPLICA STATUS\G"
  $statusText = (($status | Out-String).Trim())
  throw "MySQL replication not ready in time. Replica status:`n$statusText"
}

Invoke-ContainerSql -ContainerName "mf_mysql_replica" -User "root" -Password $rootPassword -Sql "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;"

Write-Host "P2-3 MySQL HA stack started."
Write-Host "Runtime env file: $dbHaEnv"
Write-Host "Primary: 127.0.0.1:3307 (container: mysql:3306)"
Write-Host "Replica: 127.0.0.1:3308 (container: mysql_replica:3306, read-only)"
Write-Host "Gateway: https://127.0.0.1/health"
Write-Host "Next: powershell -ExecutionPolicy Bypass -File .\test\verify_p2_3_mysql_ha.ps1 -EnvFile $dbHaEnv"














