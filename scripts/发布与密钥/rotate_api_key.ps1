Param(
  [string]$EnvFile = ".env",
  [int]$Bytes = 32,
  [int]$RetainOldCount = 1
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $EnvFile)) {
  throw "Not found: $EnvFile"
}
if ($Bytes -lt 16) {
  throw "Bytes must be >= 16"
}
if ($RetainOldCount -lt 0) {
  throw "RetainOldCount must be >= 0"
}

function Parse-CsvLine([string]$line) {
  if (-not $line) { return @() }
  return @($line.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

$buffer = New-Object byte[] $Bytes
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
$newPrimary = [Convert]::ToBase64String($buffer)

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

$oldPrimary = $map["API_KEY"]
$oldBackups = Parse-CsvLine $map["API_KEYS"]
$disabled = Parse-CsvLine $map["API_KEYS_DISABLED"]

$pool = New-Object System.Collections.Generic.List[string]
if ($oldPrimary) { $pool.Add($oldPrimary) }
foreach ($k in $oldBackups) { if (-not $pool.Contains($k)) { $pool.Add($k) } }

$newBackups = @()
foreach ($k in $pool) {
  if ($k -ne $newPrimary -and $disabled -notcontains $k) {
    $newBackups += $k
  }
}
if ($RetainOldCount -ge 0) {
  $newBackups = $newBackups | Select-Object -First $RetainOldCount
}

$newApiKeysLine = if ($newBackups.Count -gt 0) { $newBackups -join "," } else { "" }

$replacedPrimary = $false
$replacedBackups = $false
$replacedDisabled = $false

$out = @()
foreach ($line in $lines) {
  if ($line -match '^API_KEY=') {
    $out += "API_KEY=$newPrimary"
    $replacedPrimary = $true
  } elseif ($line -match '^API_KEYS=') {
    $out += "API_KEYS=$newApiKeysLine"
    $replacedBackups = $true
  } elseif ($line -match '^API_KEYS_DISABLED=') {
    $out += "API_KEYS_DISABLED=" + ($disabled -join ",")
    $replacedDisabled = $true
  } else {
    $out += $line
  }
}

if (-not $replacedPrimary) { $out += "API_KEY=$newPrimary" }
if (-not $replacedBackups) { $out += "API_KEYS=$newApiKeysLine" }
if (-not $replacedDisabled) { $out += "API_KEYS_DISABLED=" + ($disabled -join ",") }

$out | Set-Content -Encoding Ascii $EnvFile

Write-Host "API key rotation done:"
Write-Host "  New API_KEY (primary) generated"
Write-Host "  API_KEYS backups retained: $($newBackups.Count)"
Write-Host "  Disabled keys kept: $($disabled.Count)"
Write-Host "Please restart backend to apply."
