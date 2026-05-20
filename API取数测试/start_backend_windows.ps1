Param(
  [string]$RootDir = "D:\mf_api_test",
  [string]$PythonExe = "python",
  [string]$VenvDir = "venv_api_test"
)

$ErrorActionPreference = "Stop"

Set-Location $RootDir

$envFile = Join-Path $RootDir ".env.api-test"
if (-not (Test-Path $envFile)) {
  throw ".env.api-test not found: $envFile"
}

$venvPython = Join-Path $RootDir "$VenvDir\Scripts\python.exe"
$activateScript = Join-Path $RootDir "$VenvDir\Scripts\Activate.ps1"

if (-not (Test-Path $venvPython)) {
  & $PythonExe -m venv (Join-Path $RootDir $VenvDir)
}

. $activateScript
python -m pip install --upgrade pip
python -m pip install -r (Join-Path $RootDir "backend\requirements.txt")

$env:APP_ENV = "prod"
$env:ENV_FILE = $envFile
$env:APP_INSTANCE_ID = "api-test-backend"
$env:APP_RELEASE_CHANNEL = "stable"
$env:APP_RELEASE_VERSION = "api-test"
$env:ENABLE_INGESTION = "0"

Set-Location (Join-Path $RootDir "backend")
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
