Param(
  [string]$Device = "DEV-001",
  [int]$Interval = 3
)

$ErrorActionPreference = "Stop"

.\.venv\Scripts\Activate.ps1
python backend\simulator.py --host 127.0.0.1 --port 1883 --device $Device --interval $Interval
