param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$frontendDir = Join-Path $repoRoot "frontend"
$frontendDist = Join-Path $frontendDir "dist"
$backendDist = Join-Path $repoRoot "backend\frontend_dist"

if (-not (Test-Path $frontendDir)) {
  throw "frontend directory not found: $frontendDir"
}

Push-Location $frontendDir
try {
  if (-not (Test-Path (Join-Path $frontendDir "node_modules"))) {
    Write-Host "Installing frontend dependencies..."
    & npm.cmd install
    if ($LASTEXITCODE -ne 0) {
      throw "npm install failed. ExitCode=$LASTEXITCODE"
    }
  }

  Write-Host "Building Vue frontend..."
  & npx.cmd vite build --configLoader runner
  if ($LASTEXITCODE -ne 0) {
    throw "frontend build failed. ExitCode=$LASTEXITCODE"
  }
} finally {
  Pop-Location
}

if (-not (Test-Path $frontendDist)) {
  throw "frontend dist not found: $frontendDist"
}

New-Item -ItemType Directory -Path $backendDist -Force | Out-Null
Copy-Item -Path (Join-Path $frontendDist '*') -Destination $backendDist -Recurse -Force
Write-Host "Synced frontend dist to $backendDist"
