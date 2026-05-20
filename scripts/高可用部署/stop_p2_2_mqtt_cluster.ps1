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
$clusterEnv = "$envPath.ha.mqtt"
if (-not (Test-Path $clusterEnv)) {
  Write-Warning "P2-2 env file not found: $clusterEnv. Falling back to $EnvFile"
  $clusterEnv = $EnvFile
}

docker compose --env-file $clusterEnv -f docker-compose.yml -f docker-compose.p2-ha.yml -f docker-compose.p2-mqtt.yml down
if ($LASTEXITCODE -ne 0) {
  throw "Failed to stop P2-2 MQTT cluster stack."
}

Write-Host "P2-2 MQTT cluster stack stopped."
