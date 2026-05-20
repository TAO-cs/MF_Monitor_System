Param(
  [string]$RepoRoot = "."
)

$ErrorActionPreference = "Stop"

$configFile = Join-Path $RepoRoot "backend\app\config.py"
$readmeFile = Join-Path $RepoRoot "README.md"

$startupDoc = Get-ChildItem $RepoRoot -File -Filter *.txt | Where-Object {
  Select-String -Path $_.FullName -Pattern 'start_p2_3_mysql_ha\.ps1' -Quiet
} | Select-Object -First 1 -ExpandProperty FullName

if (-not $startupDoc) {
  throw "Could not locate startup instruction text file"
}

$configText = Get-Content $configFile -Raw -Encoding UTF8
$startupText = Get-Content $startupDoc -Raw -Encoding UTF8
$readmeText = Get-Content $readmeFile -Raw -Encoding UTF8

if ($configText -match 'platform_admin_password:\s*str\s*=\s*os\.getenv\("PLATFORM_ADMIN_PASSWORD",\s*"ninh1122"\)') {
  throw "backend/app/config.py still falls back to hard-coded admin password"
}

if ($configText -match 'api_key:\s*str\s*=\s*os\.getenv\("API_KEY",\s*"dev-api-key-change-me"\)') {
  throw "backend/app/config.py still falls back to hard-coded API key"
}

if ($startupText -match 'ninh1122') {
  throw "startup instruction text file still contains default admin password"
}

if ($readmeText -match 'dev-api-key-change-me') {
  throw "README.md still exposes development API key fallback"
}
