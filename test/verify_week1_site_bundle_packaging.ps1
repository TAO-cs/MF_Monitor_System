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

if ($installText -match 'cp -r "\$\{APP_SOURCE_ROOT\}" "\$\{TARGET_ROOT\}/jetson_edge_disnet_cpp"') {
  throw "install_site.sh still uses a nesting-prone recursive copy for the app source"
}

if ($installText -notmatch 'cp -a "\$\{APP_SOURCE_ROOT\}/\." "\$\{TARGET_ROOT\}/jetson_edge_disnet_cpp/"') {
  throw "install_site.sh does not copy app source contents in an idempotent way"
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

$manifestPath = Join-Path $OutputRoot "SITE01\site-manifest.json"
if (-not (Test-Path $manifestPath)) {
  throw "site manifest missing: $manifestPath"
}

$manifestText = Get-Content $manifestPath -Raw -Encoding UTF8
if ($manifestText -notmatch '"site_code"\s*:\s*"SITE01"') {
  throw "site manifest missing expected site_code"
}

if ($manifestText -notmatch '"aibox_id"\s*:\s*"MF001"') {
  throw "site manifest missing expected aibox_id"
}

foreach ($path in @(
  (Join-Path $OutputRoot "SITE01\jetson_edge_disnet_cpp\CMakeLists.txt"),
  (Join-Path $OutputRoot "SITE01\jetson_edge_disnet_cpp\scripts\run_rtsp_probe.sh"),
  (Join-Path $OutputRoot "SITE01\jetson_edge_disnet_cpp\src\main.cpp")
)) {
  if (-not (Test-Path $path)) {
    throw "site bundle missing self-contained Jetson payload file: $path"
  }
}

powershell -NoProfile -ExecutionPolicy Bypass -File $packer -OutputRoot $OutputRoot

$zipFile = Join-Path $OutputRoot "SITE01.zip"
if (-not (Test-Path $zipFile)) {
  throw "site zip package missing: $zipFile"
}

$extractRoot = Join-Path $OutputRoot "_site01_zip_extract"
if (Test-Path $extractRoot) {
  Remove-Item $extractRoot -Recurse -Force
}

Expand-Archive -Path $zipFile -DestinationPath $extractRoot -Force

foreach ($path in @(
  (Join-Path $extractRoot "SITE01\config\device.ini"),
  (Join-Path $extractRoot "SITE01\site-manifest.json"),
  (Join-Path $extractRoot "SITE01\jetson_edge_disnet_cpp\scripts\run_rtsp_probe.sh")
)) {
  if (-not (Test-Path $path)) {
    throw "packaged zip missing expected file after extraction: $path"
  }
}
