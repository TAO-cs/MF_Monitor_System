Param(
  [ValidateSet("dev", "test", "prod")]
  [string]$Env = "dev",
  [string]$EnvFile = "",
  [string]$VenvDir = "venv_MFSystem"
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

$env:APP_ENV = $Env
$env:ENV_FILE = (Resolve-Path $EnvFile).Path

powershell -ExecutionPolicy Bypass -File .\scripts\check_env.ps1 -EnvFile $EnvFile -Mode backend

$venvPython = Join-Path $VenvDir "Scripts\python.exe"
$activateScript = Join-Path $VenvDir "Scripts\Activate.ps1"

if (-not (Test-Path $venvPython)) {
  python -m venv $VenvDir
}

. $activateScript
python -m pip install -r backend\requirements.txt
Set-Location backend

if ($Env -eq "dev") {
  python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
} else {
  python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
}
