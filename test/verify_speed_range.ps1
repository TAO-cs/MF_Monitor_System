Param(
  [string]$BaseUrl = "http://127.0.0.1:8000",
  [int]$MinutesBack = 10,
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

$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("China Standard Time")
$end = [System.TimeZoneInfo]::ConvertTime((Get-Date), $tz)
$start = $end.AddMinutes(-1 * $MinutesBack)

$startStr = $start.ToString("yyyy-MM-ddTHH:mm:sszzz")
$endStr = $end.ToString("yyyy-MM-ddTHH:mm:sszzz")

$encStart = [uri]::EscapeDataString($startStr)
$encEnd = [uri]::EscapeDataString($endStr)

$query = "start_time=$encStart&end_time=$encEnd"
if ($AiboxId) { $query += "&aibox_id=$([uri]::EscapeDataString($AiboxId))" }
if ($CamId) { $query += "&cam_id=$([uri]::EscapeDataString($CamId))" }

$url = "$BaseUrl/api/speed?$query"
Write-Host "请求URL: $url"

$data = Invoke-RestMethod -Uri $url -Method Get -Headers $headers

if ($null -eq $data) {
  Write-Host "返回空。"
  exit 0
}

if ($data -isnot [System.Array]) {
  $data = @($data)
}

Write-Host "时间范围(北京时间): $startStr ~ $endStr"
Write-Host "总记录数: $($data.Count)"

$group = $data | Group-Object -Property aibox_id, cam_id | Sort-Object Count -Descending
Write-Host "按设备统计:"
$group | ForEach-Object {
  Write-Host ("  " + $_.Name + " => " + $_.Count)
}

Write-Host "最近3条(含speed长度):"
$data | Select-Object -First 3 | ForEach-Object {
  $speedLen = 0
  if ($_.speed) { $speedLen = $_.speed.Count }
  Write-Host ("  aibox_id=" + $_.aibox_id + ", cam_id=" + $_.cam_id + ", ts=" + $_.timestamp + ", speed_len=" + $speedLen)
}
