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

if ($fleetText -match 'Start-Process\s+powershell') {
  throw "fleet runner still launches simulator through a powershell wrapper instead of starting python directly"
}

if ($fleetText -match '\[string\]\$Host\s*=') {
  throw "fleet runner still uses reserved PowerShell variable name Host"
}

$startupDoc = Get-ChildItem -File | Where-Object {
  try {
    (Get-Content $_.FullName -Raw -Encoding UTF8) -match 'run_simulator_fleet\.ps1'
  } catch {
    $false
  }
} | Select-Object -First 1 -ExpandProperty FullName

if (-not $startupDoc) {
  throw "could not locate startup documentation file containing run_simulator_fleet.ps1"
}

$runbookFiles = @($startupDoc)
$runbookFiles += Get-ChildItem -File -Filter *.md | Where-Object {
  try {
    (Get-Content $_.FullName -Raw -Encoding UTF8) -match 'run_simulator_fleet\.ps1'
  } catch {
    $false
  }
} | Select-Object -ExpandProperty FullName
$runbookFiles += ".\docs\landing\week1-go-live-runbook.md"
$runbookFiles = $runbookFiles | Select-Object -Unique

foreach ($doc in $runbookFiles) {
  $docText = Get-Content $doc -Raw -Encoding UTF8
  if ($docText -match 'run_simulator_fleet\.ps1.*-Host 127\.0\.0\.1' -or $docText -match '^\s*-Host 127\.0\.0\.1' ) {
    throw "fleet rehearsal docs still use -Host instead of non-conflicting mqtt host parameter"
  }
}
