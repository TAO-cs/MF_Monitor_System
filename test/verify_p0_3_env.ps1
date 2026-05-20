Param(
  [ValidateSet("dev", "test", "prod")]
  [string]$Env = "dev",
  [string]$VenvDir = "venv_MFSystem"
)

$ErrorActionPreference = "Stop"

$envFile = ".env.$Env"
if (-not (Test-Path $envFile)) {
  throw "Missing env file: $envFile"
}

Write-Host "[1/3] Validate env file format"
powershell -ExecutionPolicy Bypass -File .\scripts\check_env.ps1 -EnvFile $envFile -Mode all

Write-Host "[2/3] Backend boot config check"
$env:APP_ENV = $Env
$env:ENV_FILE = (Resolve-Path $envFile).Path

$py = "python"
$venvPy = Join-Path $VenvDir "Scripts\python.exe"
if (Test-Path $venvPy) { $py = $venvPy }

& $py -c "from backend.app.config import Settings; s=Settings(); print(f'APP_ENV={s.app_env}'); print(f'ENV_FILE={s.env_file}'); print(f'DB={s.db_host}:{s.db_port}/{s.db_name}'); print(f'MQTT={s.mqtt_broker_host}:{s.mqtt_broker_port}'); print(f'LOG_LEVEL={s.log_level}')"

Write-Host "[3/3] PASS"
