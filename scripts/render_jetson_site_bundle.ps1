Param(
  [string]$InventoryFile = ".\deploy\inventory\devices.csv",
  [string]$TemplateFile = ".\jetson_edge_disnet_cpp\configs\templates\device.ini.template",
  [string]$OutputRoot = ".\artifacts\jetson-sites",
  [string]$EnginePath = "/home/nvidia/mudflow_project/model_onnx/EdgeDisNet_fp16_jetson.engine",
  [Parameter(Mandatory = $true)]
  [string]$EvidenceUploadApiKey
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $InventoryFile)) {
  throw "inventory file missing: $InventoryFile"
}

if (-not (Test-Path $TemplateFile)) {
  throw "template file missing: $TemplateFile"
}

$rows = Import-Csv $InventoryFile
$template = Get-Content $TemplateFile -Raw -Encoding UTF8
$deploySource = Join-Path (Resolve-Path ".\jetson_edge_disnet_cpp\deploy") ""
$jetsonSourceRoot = (Resolve-Path ".\jetson_edge_disnet_cpp").Path
$payloadItems = @(
  "CMakeLists.txt",
  "README.md",
  "deploy",
  "docs",
  "include",
  "scripts",
  "src",
  "configs\templates",
  "runtime\logs\.gitkeep",
  "runtime\snapshots\.gitkeep"
)

foreach ($row in $rows) {
  $siteDir = Join-Path $OutputRoot $row.site_code
  $configDir = Join-Path $siteDir "config"
  $deployDir = Join-Path $siteDir "deploy"
  $payloadDir = Join-Path $siteDir "jetson_edge_disnet_cpp"

  New-Item -ItemType Directory -Force -Path $configDir | Out-Null
  New-Item -ItemType Directory -Force -Path $deployDir | Out-Null
  if (Test-Path $payloadDir) {
    Remove-Item -LiteralPath $payloadDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $payloadDir | Out-Null

  $content = $template
  $content = $content.Replace("{{AIBOX_ID}}", $row.aibox_id)
  $content = $content.Replace("{{CAM_ID}}", $row.cam_id)
  $content = $content.Replace("{{VIDEO_SOURCE}}", $row.video_source)
  $content = $content.Replace("{{ENGINE_PATH}}", $EnginePath)
  $content = $content.Replace("{{MQTT_HOST}}", $row.mqtt_host)
  $content = $content.Replace("{{MQTT_PORT}}", $row.mqtt_port)
  $content = $content.Replace("{{EVIDENCE_UPLOAD_URL}}", $row.evidence_upload_url)
  $content = $content.Replace("{{EVIDENCE_UPLOAD_API_KEY}}", $EvidenceUploadApiKey)

  Set-Content -Path (Join-Path $configDir "device.ini") -Value $content -Encoding UTF8

  foreach ($relativePath in $payloadItems) {
    $sourcePath = Join-Path $jetsonSourceRoot $relativePath
    if (-not (Test-Path $sourcePath)) {
      throw "jetson payload path missing: $sourcePath"
    }

    $destinationPath = Join-Path $payloadDir $relativePath
    $destinationParent = Split-Path -Parent $destinationPath
    if ($destinationParent) {
      New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
    }

    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
  }

  $manifest = [ordered]@{
    site_code = $row.site_code
    aibox_id = $row.aibox_id
    cam_id = $row.cam_id
    device_name = $row.device_name
    location = $row.location
    latitude = $row.latitude
    longitude = $row.longitude
    video_source = $row.video_source
    mqtt_host = $row.mqtt_host
    mqtt_port = $row.mqtt_port
    evidence_upload_url = $row.evidence_upload_url
    generated_at = (Get-Date).ToString("o")
  }

  $manifest | ConvertTo-Json | Set-Content -Path (Join-Path $siteDir "site-manifest.json") -Encoding UTF8

  Copy-Item -Path (Join-Path $deploySource "install_site.sh") -Destination (Join-Path $deployDir "install_site.sh") -Force
  Copy-Item -Path (Join-Path $deploySource "rtsp_probe@.service") -Destination (Join-Path $deployDir "rtsp_probe@.service") -Force
}
