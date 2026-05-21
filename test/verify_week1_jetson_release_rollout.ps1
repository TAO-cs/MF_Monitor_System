Param(
  [string]$OutputRoot = ".\artifacts\test-jetson-rollout",
  [string]$ReleaseVersion = "2026.05.21-rc1"
)

$ErrorActionPreference = "Stop"

$serviceTemplate = ".\jetson_edge_disnet_cpp\deploy\rtsp_probe@.service"
$installer = ".\jetson_edge_disnet_cpp\deploy\install_site.sh"
$rollbackScript = ".\jetson_edge_disnet_cpp\deploy\rollback_site_update.sh"
$renderer = ".\scripts\render_jetson_site_bundle.ps1"
$rolloutPlanner = ".\scripts\render_jetson_rollout_plan.ps1"

foreach ($path in @($serviceTemplate, $installer, $renderer)) {
  if (-not (Test-Path $path)) {
    throw "required file missing: $path"
  }
}

if (-not (Test-Path $rollbackScript)) {
  throw "rollback_site_update.sh missing"
}

if (-not (Test-Path $rolloutPlanner)) {
  throw "render_jetson_rollout_plan.ps1 missing"
}

$serviceText = Get-Content $serviceTemplate -Raw -Encoding UTF8
if ($serviceText -notmatch '/opt/mf-monitor/%i/current/jetson_edge_disnet_cpp') {
  throw "service template does not run from current release symlink"
}

$installText = Get-Content $installer -Raw -Encoding UTF8
if ($installText -notmatch 'RELEASES_ROOT="\$\{SITE_ROOT\}/releases"') {
  throw "install_site.sh does not install into versioned releases root"
}

if ($installText -notmatch 'ln -sfn "\$\{TARGET_RELEASE_ROOT\}" "\$\{CURRENT_LINK\}"') {
  throw "install_site.sh does not update current release symlink"
}

if ($installText -notmatch 'PREVIOUS_LINK="\$\{SITE_ROOT\}/previous"') {
  throw "install_site.sh does not track previous release symlink"
}

$rollbackText = Get-Content $rollbackScript -Raw -Encoding UTF8
if ($rollbackText -notmatch 'CURRENT_LINK="\$\{SITE_ROOT\}/current"') {
  throw "rollback script missing current release link handling"
}

if ($rollbackText -notmatch 'PREVIOUS_LINK="\$\{SITE_ROOT\}/previous"') {
  throw "rollback script missing previous release link handling"
}

if ($rollbackText -notmatch 'ln -sfn "\$\{ROLLBACK_TARGET\}" "\$\{CURRENT_LINK\}"') {
  throw "rollback script does not restore previous release symlink"
}

$rendererText = Get-Content $renderer -Raw -Encoding UTF8
if ($rendererText -notmatch '\[string\]\$ReleaseVersion') {
  throw "render_jetson_site_bundle.ps1 does not accept ReleaseVersion"
}

if ($rendererText -notmatch 'release_version') {
  throw "render_jetson_site_bundle.ps1 does not write release_version into site manifest"
}

if ($rendererText -notmatch 'rollback_site_update\.sh') {
  throw "render_jetson_site_bundle.ps1 does not include rollback_site_update.sh in site bundles"
}

powershell -NoProfile -ExecutionPolicy Bypass -File $renderer `
  -InventoryFile ".\deploy\inventory\devices.csv" `
  -TemplateFile ".\jetson_edge_disnet_cpp\configs\templates\device.ini.template" `
  -OutputRoot $OutputRoot `
  -ReleaseVersion $ReleaseVersion `
  -EvidenceUploadApiKey "test-evidence-key"

$manifestPath = Join-Path $OutputRoot "SITE01\site-manifest.json"
$rollbackBundleScript = Join-Path $OutputRoot "SITE01\deploy\rollback_site_update.sh"

if (-not (Test-Path $manifestPath)) {
  throw "rendered site manifest missing: $manifestPath"
}

if (-not (Test-Path $rollbackBundleScript)) {
  throw "rendered rollback script missing: $rollbackBundleScript"
}

$manifestText = Get-Content $manifestPath -Raw -Encoding UTF8
if ($manifestText -notmatch '"release_version"\s*:\s*"2026\.05\.21-rc1"') {
  throw "site manifest missing expected release_version"
}

powershell -NoProfile -ExecutionPolicy Bypass -File $rolloutPlanner `
  -InventoryFile ".\deploy\inventory\devices.csv" `
  -BundleRoot $OutputRoot `
  -ReleaseVersion $ReleaseVersion

$planFile = Join-Path $OutputRoot "rollout-plan.csv"
if (-not (Test-Path $planFile)) {
  throw "rollout plan missing: $planFile"
}

$rows = Import-Csv $planFile
if ($rows.Count -lt 10) {
  throw "rollout plan must include at least 10 sites"
}

$site01 = $rows | Where-Object { $_.site_code -eq "SITE01" } | Select-Object -First 1
if (-not $site01) {
  throw "rollout plan missing SITE01"
}

if ($site01.release_version -ne $ReleaseVersion) {
  throw "rollout plan missing expected release version"
}

if ($site01.install_command -notmatch 'install_site\.sh SITE01') {
  throw "rollout plan missing install command for SITE01"
}

if ($site01.rollback_command -notmatch 'rollback_site_update\.sh SITE01') {
  throw "rollout plan missing rollback command for SITE01"
}
