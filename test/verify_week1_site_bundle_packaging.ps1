Param(
  [string]$OutputRoot = ".\artifacts\test-jetson-sites"
)

$ErrorActionPreference = "Stop"

$serviceTemplate = ".\jetson_edge_disnet_cpp\deploy\rtsp_probe@.service"
$installer = ".\jetson_edge_disnet_cpp\deploy\install_site.sh"
$renderer = ".\scripts\render_jetson_site_bundle.ps1"
$packer = ".\scripts\package_jetson_bundles.ps1"

foreach ($path in @($serviceTemplate, $installer, $renderer, $packer)) {
  if (-not (Test-Path $path)) {
    throw "required file missing: $path"
  }
}

$serviceText = Get-Content $serviceTemplate -Raw -Encoding UTF8
if ($serviceText -notmatch '/opt/mf-monitor/%i/jetson_edge_disnet_cpp') {
  throw "service template does not point to per-site working directory"
}

$installText = Get-Content $installer -Raw -Encoding UTF8
if ($installText -notmatch '/opt/mf-monitor/\$\{SITE_CODE\}') {
  throw "install_site.sh does not install into per-site target root"
}

powershell -NoProfile -ExecutionPolicy Bypass -File $renderer `
  -InventoryFile ".\deploy\inventory\devices.csv" `
  -TemplateFile ".\jetson_edge_disnet_cpp\configs\templates\device.ini.template" `
  -OutputRoot $OutputRoot `
  -EvidenceUploadApiKey "test-evidence-key"

$renderedConfig = Join-Path $OutputRoot "SITE01\config\device.ini"
if (-not (Test-Path $renderedConfig)) {
  throw "rendered site config missing: $renderedConfig"
}

$renderedText = Get-Content $renderedConfig -Raw -Encoding UTF8
if ($renderedText -notmatch 'video_source=/data/mock/site01.mp4') {
  throw "rendered config missing expected video_source"
}

if ($renderedText -notmatch 'evidence_upload_api_key=test-evidence-key') {
  throw "rendered config missing expected evidence upload api key"
}

powershell -NoProfile -ExecutionPolicy Bypass -File $packer -OutputRoot $OutputRoot

$zipFile = Join-Path $OutputRoot "SITE01.zip"
if (-not (Test-Path $zipFile)) {
  throw "site zip package missing: $zipFile"
}
