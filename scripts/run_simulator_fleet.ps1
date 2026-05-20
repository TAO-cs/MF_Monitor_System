Param(
  [string]$InventoryFile = ".\deploy\inventory\devices.csv",
  [string]$Host = "127.0.0.1",
  [int]$Port = 1883,
  [int]$Interval = 5,
  [string]$PythonExe = ".\venv_MFSystem\Scripts\python.exe"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $InventoryFile)) {
  throw "inventory file missing: $InventoryFile"
}

if (-not (Test-Path $PythonExe)) {
  $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
  if ($null -eq $pythonCommand) {
    throw "python executable not found: $PythonExe"
  }
  $PythonExe = $pythonCommand.Source
}

$rows = Import-Csv $InventoryFile
if (-not $rows -or $rows.Count -eq 0) {
  throw "inventory contains no device rows: $InventoryFile"
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$pythonPath = Resolve-Path $PythonExe

foreach ($row in $rows) {
  Start-Process powershell `
    -WindowStyle Hidden `
    -WorkingDirectory $repoRoot `
    -ArgumentList @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-Command",
      "& `"$pythonPath`" .\backend\simulator.py --host $Host --port $Port --device $($row.aibox_id) --cam $($row.cam_id) --interval $Interval"
    ) | Out-Null

  Write-Host ("[started] {0} {1}/{2}" -f $row.site_code, $row.aibox_id, $row.cam_id)
}
