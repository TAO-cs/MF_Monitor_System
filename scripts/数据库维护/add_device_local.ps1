Param(
  [string]$MysqlExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysql.exe",
  [string]$User = "Evil_Pidan_King",
  [string]$DbHost = "127.0.0.1",
  [int]$Port = 3306,
  [string]$Database = "mf_monitor",
  [string]$AiboxId = "MF002",
  [string]$CamId = "CAM002",
  [string]$Location = "测试点B",
  [double]$Latitude = 34.15,
  [double]$Longitude = 118.15,
  [string]$OnlineStatus = "on"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $MysqlExe)) {
  throw "mysql.exe not found: $MysqlExe"
}

$SecurePwd = Read-Host "请输入 MySQL 密码(用户: $User)" -AsSecureString
$BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePwd)
$PlainPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

$sql = @"
INSERT INTO device_location (aibox_id, cam_id, location, latitude, longitude)
VALUES ('$AiboxId', '$CamId', '$Location', $Latitude, $Longitude)
ON DUPLICATE KEY UPDATE
  location = VALUES(location),
  latitude = VALUES(latitude),
  longitude = VALUES(longitude);

INSERT INTO device_status (aibox_id, cam_id, online_status, last_update)
VALUES ('$AiboxId', '$CamId', '$OnlineStatus', NOW())
ON DUPLICATE KEY UPDATE
  online_status = VALUES(online_status),
  last_update = VALUES(last_update);

SELECT aibox_id, cam_id, location, latitude, longitude
FROM device_location
WHERE aibox_id = '$AiboxId' AND cam_id = '$CamId';
"@

try {
  $env:MYSQL_PWD = $PlainPwd
  & $MysqlExe -h $DbHost -P $Port -u $User -D $Database -e $sql
  Write-Host "设备初始化完成: $AiboxId / $CamId"
}
finally {
  Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}
