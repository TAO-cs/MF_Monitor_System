Param(
  [string]$InventoryFile = ".\deploy\inventory\devices.csv"
)

$ErrorActionPreference = "Stop"

$fleetScript = ".\scripts\run_simulator_fleet.ps1"
if (-not (Test-Path $fleetScript)) {
  throw "scripts/run_simulator_fleet.ps1 missing"
}

$rows = Import-Csv $InventoryFile
if ($rows.Count -lt 10) {
  throw "fleet rehearsal requires at least 10 devices"
}

$fleetText = Get-Content $fleetScript -Raw -Encoding UTF8
if ($fleetText -notmatch 'Start-Process') {
  throw "fleet runner does not launch simulator processes"
}

if ($fleetText -notmatch '--device' -or $fleetText -notmatch '--cam') {
  throw "fleet runner does not pass device identity to simulator"
}
