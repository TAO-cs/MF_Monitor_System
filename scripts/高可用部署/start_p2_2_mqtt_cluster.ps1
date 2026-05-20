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

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check_env.ps1 -EnvFile $EnvFile -Mode compose

$envPath = (Resolve-Path $EnvFile).Path
$clusterEnv = "$envPath.ha.mqtt"

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

Set-Content -Path $clusterEnv -Value $out -Encoding UTF8

if (-not (Test-Path "nginx/certs/server.crt") -or -not (Test-Path "nginx/certs/server.key")) {
  Write-Host "Nginx cert not found, generating self-signed cert..."
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\gen_nginx_cert.ps1
}

$env:HA_ENV_FILE = $clusterEnv
$env:APP_ENV = $Env
$env:BACKEND_BASE_IMAGE = Resolve-P26BackendBaseImage

docker compose --env-file $clusterEnv -f docker-compose.yml -f docker-compose.p2-ha.yml -f docker-compose.p2-mqtt.yml up -d --build mysql mqtt_primary mqtt_secondary mqtt backend_api_1 backend_api_2 backend_worker nginx
if ($LASTEXITCODE -ne 0) {
  throw "Failed to start P2-2 MQTT cluster stack."
}

Write-Host "P2-2 MQTT cluster stack started."
Write-Host "Runtime env file: $clusterEnv"
Write-Host "Gateway: https://127.0.0.1/health"
Write-Host "Backend nodes: http://127.0.0.1:18001/health, http://127.0.0.1:18002/health, http://127.0.0.1:18003/health"
Write-Host "MQTT proxy: tcp://127.0.0.1:1883, ws://127.0.0.1:9001"
Write-Host "MQTT proxy stats: http://127.0.0.1:8404/stats"
Write-Host "Broker direct ports: mqtt_primary=1884, mqtt_secondary=1885"
Write-Host "Next: powershell -ExecutionPolicy Bypass -File .\test\verify_p2_2_mqtt_cluster.ps1 -EnvFile $clusterEnv"




