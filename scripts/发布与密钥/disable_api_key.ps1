Param(
  [Parameter(Mandatory = $true)]
  [string]$Key,
  [string]$EnvFile = ".env"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $EnvFile)) {
  throw "Not found: $EnvFile"
}

function Parse-CsvLine([string]$line) {
  if (-not $line) { return @() }
  return @($line.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

$lines = Get-Content $EnvFile
$map = @{}
foreach ($line in $lines) {
  if ($line -match '^\s*#') { continue }
  $idx = $line.IndexOf('=')
  if ($idx -gt 0) {
    $k = $line.Substring(0, $idx)
    $v = $line.Substring($idx + 1)
    $map[$k] = $v
  }
}

$primary = $map["API_KEY"]
$backups = Parse-CsvLine $map["API_KEYS"]
$disabled = Parse-CsvLine $map["API_KEYS_DISABLED"]

if ($primary -eq $Key) {
  throw "Refuse to disable current primary API_KEY directly. Rotate first, then disable old key."
}

if ($disabled -notcontains $Key) {
  $disabled += $Key
}

$backups = @($backups | Where-Object { $_ -ne $Key })

$replacedBackups = $false
$replacedDisabled = $false
$out = @()
foreach ($line in $lines) {
  if ($line -match '^API_KEYS=') {
    $out += "API_KEYS=" + ($backups -join ",")
    $replacedBackups = $true
  } elseif ($line -match '^API_KEYS_DISABLED=') {
    $out += "API_KEYS_DISABLED=" + ($disabled -join ",")
    $replacedDisabled = $true
  } else {
    $out += $line
  }
}

if (-not $replacedBackups) { $out += "API_KEYS=" + ($backups -join ",") }
if (-not $replacedDisabled) { $out += "API_KEYS_DISABLED=" + ($disabled -join ",") }

$out | Set-Content -Encoding Ascii $EnvFile

Write-Host "Disabled API key (moved to API_KEYS_DISABLED)."
Write-Host "Please restart backend to apply."
