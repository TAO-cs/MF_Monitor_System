Param(
  [string]$EnvFile = ".env",
  [ValidateSet("backend", "compose", "all")]
  [string]$Mode = "all"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $EnvFile)) {
  throw "Env file not found: $EnvFile"
}

$requiredBackend = @(
  "DB_HOST",
  "DB_PORT",
  "DB_NAME",
  "DB_USER",
  "DB_PASSWORD",
  "MQTT_BROKER_HOST",
  "MQTT_BROKER_PORT",
  "API_KEY",
  "PLATFORM_ADMIN_USERNAME",
  "PLATFORM_ADMIN_PASSWORD"
)

$requiredCompose = @(
  "MYSQL_ROOT_PASSWORD",
  "MYSQL_DATABASE",
  "MYSQL_USER",
  "MYSQL_PASSWORD"
)

$map = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
  $parts = $_.Split('=', 2)
  $map[$parts[0].Trim()] = $parts[1]
}

$required = @()
if ($Mode -eq "backend") {
  $required = $requiredBackend
} elseif ($Mode -eq "compose") {
  $required = $requiredCompose
} else {
  $required = $requiredBackend + $requiredCompose
}

$missing = @()
foreach ($k in $required) {
  if (-not $map.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($map[$k])) {
    $missing += $k
  }
}

if ($missing.Count -gt 0) {
  throw "Env validation failed for $EnvFile. Missing: $($missing -join ', ')"
}

Write-Host "Env validation OK: $EnvFile (mode=$Mode)"
