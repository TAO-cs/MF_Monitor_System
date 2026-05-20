Param(
  [string]$MysqlExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysql.exe",
  [string]$User = "Evil_Pidan_King",
  [string]$DbHost = "127.0.0.1",
  [int]$Port = 3306,
  [string]$Database = "mf_monitor",
  [string]$ApiBase = "http://127.0.0.1:8000",
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

function Get-Counts {
  param([string]$MysqlExe,[string]$DbHost,[int]$Port,[string]$User,[string]$Database)
  $query = @"
SELECT
  (SELECT COUNT(*) FROM disaster_data) AS disaster_count,
  (SELECT COUNT(*) FROM speed_data) AS speed_count,
  (SELECT COUNT(*) FROM device_status) AS status_count;
"@
  $raw = & $MysqlExe -h $DbHost -P $Port -u $User -D $Database -N -e $query
  $parts = $raw.Trim() -split "\s+"
  return [pscustomobject]@{
    disaster = [int]$parts[0]
    speed = [int]$parts[1]
    status = [int]$parts[2]
  }
}

if (-not (Test-Path $MysqlExe)) {
  throw "mysql.exe not found: $MysqlExe"
}

$SecurePwd = Read-Host "请输入 MySQL 密码(用户: $User)" -AsSecureString
$BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePwd)
$PlainPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

try {
  $env:MYSQL_PWD = $PlainPwd

  Write-Host "[1/4] 读取写入前计数..."
  $before = Get-Counts -MysqlExe $MysqlExe -DbHost $DbHost -Port $Port -User $User -Database $Database
  Write-Host "before => disaster=$($before.disaster), speed=$($before.speed), status=$($before.status)"

  Write-Host "[2/4] 发送脏 MQTT 数据..."

  $msg1 = '{"disaster_id":"BAD001","disaster_type":"flood","timestamp":"2026-04-02T12:00:00+08:00","confidence":1.5,"aibox_id":"MF001","cam_id":"CAM001"}'
  docker exec mf_mqtt sh -c "mosquitto_pub -h 127.0.0.1 -p 1883 -t disaster_monitoring/MF001/classification -m '$msg1'"

  $msg2 = '{"disaster_id":"BAD002","disaster_type":"xxx","timestamp":"2026-04-02T12:00:00+08:00","confidence":0.8,"aibox_id":"MF001","cam_id":"CAM001"}'
  docker exec mf_mqtt sh -c "mosquitto_pub -h 127.0.0.1 -p 1883 -t disaster_monitoring/MF001/classification -m '$msg2'"

  $msg3 = '{"aibox_id":"MF001","cam_id":"CAM001","timestamp":"2026-04-02T12:00:00+08:00","disaster_type":"flood","speed":[1.2,-0.3,0.8]}'
  docker exec mf_mqtt sh -c "mosquitto_pub -h 127.0.0.1 -p 1883 -t disaster_monitoring/MF001/speed -m '$msg3'"

  $msg4 = '{"aibox_id":"MF001","cam_id":"CAM001","online_status":"unknown","timestamp":"2026-04-02T12:00:00+08:00"}'
  docker exec mf_mqtt sh -c "mosquitto_pub -h 127.0.0.1 -p 1883 -t disaster_monitoring/MF001/device_status -m '$msg4'"

  docker exec mf_mqtt sh -c "mosquitto_pub -h 127.0.0.1 -p 1883 -t disaster_monitoring/MF001/classification -m '{bad_json}'"

  Start-Sleep -Seconds 2

  Write-Host "[3/4] 读取写入后计数..."
  $after = Get-Counts -MysqlExe $MysqlExe -DbHost $DbHost -Port $Port -User $User -Database $Database
  Write-Host "after  => disaster=$($after.disaster), speed=$($after.speed), status=$($after.status)"

  if ($before.disaster -eq $after.disaster -and $before.speed -eq $after.speed -and $before.status -eq $after.status) {
    Write-Host "MQTT脏数据测试通过: 计数未增长（非法消息被拦截）。"
  } else {
    Write-Host "MQTT脏数据测试异常: 计数发生变化，请检查后端日志。"
  }

  Write-Host "[4/4] API脏参数测试..."
  try {
    Invoke-RestMethod -Uri "$ApiBase/api/classification?start_time=2026-04-02T13:00:00%2B08:00&end_time=2026-04-02T12:00:00%2B08:00" -Method Get -Headers $headers | Out-Null
    Write-Host "API时间范围测试异常: 预期400但未报错。"
  } catch {
    Write-Host "API时间范围测试通过: 返回错误（预期）。"
  }

  try {
    $longId = "A" * 60
    Invoke-RestMethod -Uri "$ApiBase/api/device_status?aibox_id=$longId" -Method Get -Headers $headers | Out-Null
    Write-Host "API长度校验测试异常: 预期422但未报错。"
  } catch {
    Write-Host "API长度校验测试通过: 返回错误（预期）。"
  }

}
finally {
  Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}
