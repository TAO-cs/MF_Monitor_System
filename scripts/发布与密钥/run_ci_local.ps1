Param(
  [ValidateSet('dev', 'test', 'prod')]
  [string]$Env = 'dev',
  [switch]$SkipDockerBuild
)

$ErrorActionPreference = 'Stop'

function Parse-PowerShellFile {
  param([string]$Path)

  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) {
    $messages = $errors | ForEach-Object { $_.Message }
    throw "PowerShell parse failed: $Path`n$($messages -join "`n")"
  }
}

function Get-LocalDockerImages {
  $raw = & docker images --format "{{.Repository}}:{{.Tag}}"
  if ($LASTEXITCODE -ne 0) {
    throw 'docker images failed'
  }
  return @($raw)
}

function Resolve-LocalCiBaseImage {
  if ($env:BACKEND_BASE_IMAGE) {
    return $env:BACKEND_BASE_IMAGE
  }

  $localImages = Get-LocalDockerImages

  if ($localImages -contains 'python:3.12-slim') {
    return 'python:3.12-slim'
  }

  $fallbacks = @(
    'mf_monitor_system-backend_api_1:latest',
    'mf_monitor_system-backend_api_2:latest',
    'mf_monitor_system-backend_worker:latest'
  )

  foreach ($image in $fallbacks) {
    if ($localImages -contains $image) {
      Write-Warning "Base image python:3.12-slim unavailable locally, fallback to $image for offline CI build"
      return $image
    }
  }

  throw 'No usable Docker base image found locally. Pull python:3.12-slim or build HA backend images first.'
}


Write-Host '[1/4] Validate env files'
$envCandidates = @('.env.dev', '.env.test', '.env.prod') | Where-Object { Test-Path $_ }
foreach ($envFile in $envCandidates) {
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check_env.ps1 -EnvFile $envFile -Mode all
  if ($LASTEXITCODE -ne 0) {
    throw "check_env failed: $envFile"
  }
}
Write-Host "  env validation ok ($($envCandidates.Count) files)"

Write-Host '[2/4] Python syntax compile'
$pythonExe = if (Test-Path '.\venv_MFSystem\Scripts\python.exe') { '.\venv_MFSystem\Scripts\python.exe' } else { 'python' }
$pyFiles = Get-ChildItem -Path .\backend -Recurse -Filter *.py | ForEach-Object { $_.FullName }
if (-not $pyFiles -or $pyFiles.Count -lt 1) {
  throw 'No Python files found under backend/'
}
& $pythonExe -m py_compile @pyFiles
if ($LASTEXITCODE -ne 0) {
  throw 'py_compile failed'
}
Write-Host "  py_compile ok ($($pyFiles.Count) files)"

Write-Host '[3/4] PowerShell script parse'
$psFiles = @(
  Get-ChildItem .\scripts -Filter *.ps1 | ForEach-Object { $_.FullName }
  Get-ChildItem .\test -Filter *.ps1 | ForEach-Object { $_.FullName }
)
foreach ($psFile in $psFiles) {
  Parse-PowerShellFile -Path $psFile
}
Write-Host "  powershell parse ok ($($psFiles.Count) files)"

Write-Host '[4/4] Backend image build'
if ($SkipDockerBuild) {
  Write-Host '  skip docker build by flag'
} else {
  $baseImage = Resolve-LocalCiBaseImage
  Write-Host "  docker base image: $baseImage"
  & docker build --pull=false --build-arg BASE_IMAGE=$baseImage -t mf-monitor-ci:local .\backend
  if ($LASTEXITCODE -ne 0) {
    throw 'docker build failed'
  }
  Write-Host '  docker build ok (mf-monitor-ci:local)'
}

Write-Host 'PASS: P2-6 local CI baseline works'
