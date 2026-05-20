Param(
  [string]$InventoryFile = ".\deploy\inventory\devices.csv"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $InventoryFile)) {
  throw "inventory file missing: $InventoryFile"
}

$rows = Import-Csv $InventoryFile
if ($rows.Count -ne 10) {
  throw "inventory must contain exactly 10 Jetson rows for week-1 landing"
}

$requiredColumns = @(
  "site_code","aibox_id","cam_id","device_name","location","latitude","longitude",
  "video_source","mqtt_host","mqtt_port","evidence_upload_url","enabled"
)

foreach ($column in $requiredColumns) {
  if (-not ($rows[0].PSObject.Properties.Name -contains $column)) {
    throw "inventory missing column: $column"
  }
}
