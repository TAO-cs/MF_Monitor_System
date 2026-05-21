Param(
  [string]$InventoryFile = ".\deploy\inventory\devices.csv",
  [string]$BundleRoot = ".\artifacts\jetson-sites",
  [string]$ReleaseVersion = "",
  [string]$PlanFile = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $InventoryFile)) {
  throw "inventory file missing: $InventoryFile"
}

if (-not (Test-Path $BundleRoot)) {
  throw "bundle root missing: $BundleRoot"
}

if (-not $ReleaseVersion) {
  $ReleaseVersion = Get-Date -Format "yyyy.MM.dd-HHmmss"
}

if (-not $PlanFile) {
  $PlanFile = Join-Path $BundleRoot "rollout-plan.csv"
}

$rows = Import-Csv $InventoryFile
$planRows = foreach ($row in $rows) {
  $siteRoot = Join-Path $BundleRoot $row.site_code
  $zipPath = Join-Path $BundleRoot ($row.site_code + ".zip")
  if (-not (Test-Path $siteRoot)) {
    throw "site bundle directory missing: $siteRoot"
  }

  [pscustomobject]@{
    site_code = $row.site_code
    aibox_id = $row.aibox_id
    cam_id = $row.cam_id
    release_version = $ReleaseVersion
    package_zip = $(if (Test-Path $zipPath) { $zipPath } else { "" })
    install_command = "sudo bash /path/to/$($row.site_code)/deploy/install_site.sh $($row.site_code) /path/to/$($row.site_code) $ReleaseVersion"
    rollback_command = "sudo bash /path/to/$($row.site_code)/deploy/rollback_site_update.sh $($row.site_code)"
  }
}

$planRows | Export-Csv -Path $PlanFile -NoTypeInformation -Encoding UTF8
