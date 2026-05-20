Param(
  [string]$Device = "MF001",
  [string]$Cam = "CAM001",
  [int]$Interval = 3,
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

$activateScript = Join-Path $VenvDir "Scripts\Activate.ps1"
if (-not (Test-Path $activateScript)) {
  throw "Virtual env not found: $VenvDir. Please run scripts\\run_backend.ps1 first."
}

$envMap = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
  $parts = $_.Split('=', 2)
  $envMap[$parts[0]] = $parts[1]
}

$mqttHost = if ($envMap.ContainsKey('MQTT_BROKER_HOST')) { $envMap['MQTT_BROKER_HOST'] } else { '127.0.0.1' }
$mqttPort = if ($envMap.ContainsKey('MQTT_BROKER_PORT')) { [int]$envMap['MQTT_BROKER_PORT'] } else { 1883 }

$env:APP_ENV = $Env
$env:ENV_FILE = (Resolve-Path $EnvFile).Path

. $activateScript
python backend\simulator.py --host $mqttHost --port $mqttPort --device $Device --cam $Cam --interval $Interval
