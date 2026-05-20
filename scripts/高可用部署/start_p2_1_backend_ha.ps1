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
$haEnv = "$envPath.ha"

$legacyHaPath = Join-Path (Resolve-Path .\nginx\conf.d).Path "default_ha.conf"
if (Test-Path $legacyHaPath -PathType Container) {
  Remove-Item -LiteralPath $legacyHaPath -Recurse -Force
  Write-Host "Removed legacy directory: nginx\\conf.d\\default_ha.conf"
}

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

Set-Content -Path $haEnv -Value $out -Encoding UTF8

if (-not (Test-Path "nginx/certs/server.crt") -or -not (Test-Path "nginx/certs/server.key")) {
  Write-Host "Nginx cert not found, generating self-signed cert..."
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\gen_nginx_cert.ps1
}

$env:HA_ENV_FILE = $haEnv
$env:APP_ENV = $Env
$env:BACKEND_BASE_IMAGE = Resolve-P26BackendBaseImage

docker compose --env-file $haEnv -f docker-compose.yml -f docker-compose.p2-ha.yml up -d --build mysql mqtt backend_api_1 backend_api_2 backend_worker nginx
if ($LASTEXITCODE -ne 0) {
  throw "Failed to start P2-1 backend HA stack."
}

Write-Host "P2-1 backend HA stack started."
Write-Host "Runtime env file: $haEnv"
Write-Host "Gateway: https://127.0.0.1/health"
Write-Host "Direct nodes: http://127.0.0.1:18001/health, http://127.0.0.1:18002/health"
Write-Host "Worker: http://127.0.0.1:18003/health"
Write-Host "Next: powershell -ExecutionPolicy Bypass -File .\test\verify_p2_1_backend_ha.ps1 -EnvFile $haEnv"




