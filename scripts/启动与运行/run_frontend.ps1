param(
  [int]$Port = 5173
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$frontendDir = Join-Path $repoRoot "frontend"

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

  Write-Host "Starting Vue frontend on http://127.0.0.1:$Port ..."
  & npx.cmd vite --host 0.0.0.0 --port $Port --configLoader runner
} finally {
  Pop-Location
}
