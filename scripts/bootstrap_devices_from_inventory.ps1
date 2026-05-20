Param(
  [string]$InventoryFile = ".\deploy\inventory\devices.csv",
  [string]$BaseUrl = "https://127.0.0.1",
  [Parameter(Mandatory = $true)]
  [string]$ApiKey,
  [switch]$SkipExisting,
  [switch]$AllowInsecureTls
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $InventoryFile)) {
  throw "inventory file missing: $InventoryFile"
}

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  throw "ApiKey is required"
}

if ($AllowInsecureTls) {
  try {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
  } catch {
    Write-Warning "failed to enable insecure TLS bypass: $($_.Exception.Message)"
  }
}

$rows = Import-Csv $InventoryFile
if (-not $rows -or $rows.Count -eq 0) {
  throw "inventory contains no device rows: $InventoryFile"
}

$headers = @{
  Authorization = "Bearer $ApiKey"
}
$normalizedBaseUrl = $BaseUrl.TrimEnd("/")

foreach ($row in $rows) {
  $payload = @{
    aibox_id = $row.aibox_id
    cam_id = $row.cam_id
    device_name = $row.device_name
    device_type = "monitor_node"
    enabled = [bool]::Parse($row.enabled)
    allow_config_push = $true
    allow_remote_control = $false
    metadata_json = @{
      site_code = $row.site_code
      video_source = $row.video_source
      mqtt_host = $row.mqtt_host
      mqtt_port = [int]$row.mqtt_port
      evidence_upload_url = $row.evidence_upload_url
    }
    location = $row.location
    latitude = [double]$row.latitude
    longitude = [double]$row.longitude
  }

  try {
    $response = Invoke-RestMethod `
      -Uri "$normalizedBaseUrl/api/devices" `
      -Method Post `
      -Headers $headers `
      -Body ($payload | ConvertTo-Json -Depth 6) `
      -ContentType "application/json"

    Write-Host ("[created] {0}/{1}" -f $row.site_code, $row.aibox_id)
    $response
  } catch {
    $statusCode = $null
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $statusCode = [int]$_.Exception.Response.StatusCode
    }

    if ($SkipExisting -and $statusCode -eq 409) {
      Write-Warning ("[skipped] device already exists: {0}/{1}" -f $row.site_code, $row.aibox_id)
      continue
    }

    throw
  }
}
