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

$envPath = (Resolve-Path $EnvFile).Path
$haEnv = "$envPath.ha"

if (-not (Test-Path $haEnv)) {
  Write-Warning "HA env file not found: $haEnv. Falling back to $EnvFile"
  $haEnv = $EnvFile
}

docker compose --env-file $haEnv -f docker-compose.yml -f docker-compose.p2-ha.yml down
if ($LASTEXITCODE -ne 0) {
  throw "Failed to stop P2-1 backend HA stack."
}

Write-Host "P2-1 backend HA stack stopped."