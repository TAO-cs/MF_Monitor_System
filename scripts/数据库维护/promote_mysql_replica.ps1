Param(
  [ValidateSet("dev", "test", "prod")]
  [string]$Env = "dev",
  [string]$EnvFile = "",
  [switch]$GeneratePromotedEnv
)

$ErrorActionPreference = "Stop"

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

$envPath = (Resolve-Path $EnvFile).Path
$dbHaEnv = "$envPath.ha.mqtt.dbha"
if (-not (Test-Path $dbHaEnv)) {
  throw "P2-3 runtime env not found: $dbHaEnv. Start P2-3 stack first."
}

$rootPassword = ((Get-Content $dbHaEnv | Select-String '^MYSQL_ROOT_PASSWORD=' | ForEach-Object { $_.Line -replace '^MYSQL_ROOT_PASSWORD=', '' } | Select-Object -First 1) | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($rootPassword)) {
  throw "MYSQL_ROOT_PASSWORD missing in $dbHaEnv"
}

$running = (docker inspect -f '{{.State.Running}}' mf_mysql_replica 2>$null)
if ($LASTEXITCODE -ne 0 -or $running.Trim() -ne 'true') {
  throw "Container mf_mysql_replica is not running"
}

Write-Host "Promoting replica to writable primary role..."

$mysqlArgs = @("exec", "mf_mysql_replica", "mysql", "-uroot", "-p$rootPassword")

& docker @mysqlArgs -e "STOP REPLICA;"
if ($LASTEXITCODE -ne 0) { throw "STOP REPLICA failed" }

& docker @mysqlArgs -e "RESET REPLICA ALL;"
if ($LASTEXITCODE -ne 0) { throw "RESET REPLICA ALL failed" }

& docker @mysqlArgs -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"
if ($LASTEXITCODE -ne 0) { throw "disable read-only failed" }

$roLine = (& docker @mysqlArgs -N -s -e "SELECT CONCAT(@@GLOBAL.read_only, ',', @@GLOBAL.super_read_only);")
$roLine = (($roLine | Out-String).Trim())
if ($roLine -ne '0,0') {
  throw "promotion check failed, read_only flags are: $roLine"
}

Write-Host "Replica promoted (read_only=$roLine)."

if ($GeneratePromotedEnv) {
  $promoted = "$dbHaEnv.promoted"
  $lines = Get-Content $dbHaEnv
  $out = @()
  foreach ($line in $lines) {
    if ($line -match '^DB_HOST=') {
      $out += 'DB_HOST=mysql_replica'
    } elseif ($line -match '^DB_PORT=') {
      $out += 'DB_PORT=3306'
    } else {
      $out += $line
    }
  }

  Set-Content -Path $promoted -Value $out

  Write-Host "Generated promoted env file: $promoted"
  Write-Host "To repoint backend to promoted DB, run:"
  Write-Host "`$env:HA_ENV_FILE=$promoted"
  Write-Host "docker compose --env-file $promoted -f docker-compose.yml -f docker-compose.p2-ha.yml -f docker-compose.p2-mqtt.yml -f docker-compose.p2-mysql-ha.yml up -d backend_api_1 backend_api_2 backend_worker nginx"
}

Write-Host "Promotion script finished."

