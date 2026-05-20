Param(
  [ValidateSet("dev", "test", "prod")]
  [string]$Env = "dev",
  [string]$EnvFile = ""
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
  Write-Warning "P2-3 env file not found: $dbHaEnv. Falling back to $EnvFile"
  $dbHaEnv = $EnvFile
}

docker compose --env-file $dbHaEnv -f docker-compose.yml -f docker-compose.p2-ha.yml -f docker-compose.p2-mqtt.yml -f docker-compose.p2-mysql-ha.yml down
if ($LASTEXITCODE -ne 0) {
  throw "Failed to stop P2-3 MySQL HA stack."
}

Write-Host "P2-3 MySQL HA stack stopped."
