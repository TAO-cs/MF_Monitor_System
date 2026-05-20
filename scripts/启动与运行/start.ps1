Param(
  [ValidateSet("dev", "test", "prod")]
  [string]$Env = "dev",
  [string]$EnvFile = "",
  [switch]$SkipNginx,
  [switch]$SkipMysql
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

powershell -ExecutionPolicy Bypass -File .\scripts\check_env.ps1 -EnvFile $EnvFile -Mode compose

function Start-ComposeServices {
  param([string[]]$Services)
  docker compose --env-file $EnvFile up -d @Services
  return $LASTEXITCODE
}

$useMysql = -not $SkipMysql

if (-not $SkipNginx) {
  if (-not (Test-Path "nginx/certs/server.crt") -or -not (Test-Path "nginx/certs/server.key")) {
    Write-Host "Nginx cert not found, generating self-signed cert..."
    powershell -ExecutionPolicy Bypass -File .\scripts\gen_nginx_cert.ps1
  }

  if ($useMysql) {
    $code = Start-ComposeServices -Services @("mysql", "mqtt", "nginx")
    if ($code -ne 0) {
      Write-Warning "MySQL container start failed (likely local port conflict). Falling back to mqtt+nginx."
      $code2 = Start-ComposeServices -Services @("mqtt", "nginx")
      if ($code2 -ne 0) { throw "Failed to start mqtt+nginx." }
      Write-Host "MQTT + Nginx started (using local MySQL)."
    } else {
      Write-Host "MySQL + MQTT + Nginx started."
    }
  } else {
    $code = Start-ComposeServices -Services @("mqtt", "nginx")
    if ($code -ne 0) { throw "Failed to start mqtt+nginx." }
    Write-Host "MQTT + Nginx started (MySQL skipped)."
  }

  Write-Host "HTTPS gateway: https://127.0.0.1/health"
} else {
  if ($useMysql) {
    $code = Start-ComposeServices -Services @("mysql", "mqtt")
    if ($code -ne 0) {
      Write-Warning "MySQL container start failed (likely local port conflict). Falling back to mqtt only."
      $code2 = Start-ComposeServices -Services @("mqtt")
      if ($code2 -ne 0) { throw "Failed to start mqtt." }
      Write-Host "MQTT started (using local MySQL)."
    } else {
      Write-Host "MySQL + MQTT started (Nginx skipped)."
    }
  } else {
    $code = Start-ComposeServices -Services @("mqtt")
    if ($code -ne 0) { throw "Failed to start mqtt." }
    Write-Host "MQTT started (MySQL skipped, Nginx skipped)."
  }
}

Write-Host "Env mode: $Env, env file: $EnvFile"
Write-Host "Next steps:"
Write-Host "1) .\venv_MFSystem\Scripts\Activate.ps1"
Write-Host "2) .\scripts\run_backend.ps1 -Env $Env"
Write-Host "3) Optional simulator: .\scripts\run_simulator.ps1 -Env $Env -Device MF001 -Cam CAM001 -Interval 3"
