Param(
  [string]$BaseUrl = "http://127.0.0.1:8000",
  [string]$AiboxId = "",
  [string]$CamId = "",
  [string]$ApiKey = ""
)

$ErrorActionPreference = "Stop"

if (-not $ApiKey) {
  if (Test-Path ".env") {
    $line = Get-Content ".env" | Where-Object { $_ -match '^API_KEY=' } | Select-Object -First 1
    if ($line) { $ApiKey = $line.Substring(8) }
  }
}
if (-not $ApiKey) { throw "未提供 ApiKey 且 .env 中未找到 API_KEY" }

$headers = @{ Authorization = "Bearer $ApiKey" }

$queryParts = @()
if ($AiboxId) { $queryParts += "aibox_id=$([uri]::EscapeDataString($AiboxId))" }
if ($CamId) { $queryParts += "cam_id=$([uri]::EscapeDataString($CamId))" }

$url = "$BaseUrl/api/device_status"
if ($queryParts.Count -gt 0) {
  $url += "?" + ($queryParts -join "&")
}

Write-Host "请求URL: $url"
$data = Invoke-RestMethod -Uri $url -Method Get -Headers $headers

if ($null -eq $data) {
  Write-Host "返回空。"
  exit 0
}

if ($data -isnot [System.Array]) {
  $data = @($data)
}

Write-Host "总记录数: $($data.Count)"

$deviceGroup = $data | Group-Object -Property aibox_id, cam_id | Sort-Object Name
Write-Host "按设备统计:"
$deviceGroup | ForEach-Object {
  Write-Host ("  " + $_.Name + " => " + $_.Count)
}

$statusGroup = $data | Group-Object -Property online_status | Sort-Object Name
Write-Host "按状态统计:"
$statusGroup | ForEach-Object {
  Write-Host ("  " + $_.Name + " => " + $_.Count)
}

Write-Host "最近5条:"
$data | Select-Object -First 5 | ForEach-Object {
  Write-Host ("  aibox_id=" + $_.aibox_id + ", cam_id=" + $_.cam_id + ", online_status=" + $_.online_status + ", last_update=" + $_.last_update)
}
