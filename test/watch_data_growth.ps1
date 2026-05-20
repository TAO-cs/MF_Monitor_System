Param(
  [string]$MysqlExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysql.exe",
  [string]$User = "Evil_Pidan_King",
  [string]$DbHost = "127.0.0.1",
  [int]$Port = 3306,
  [string]$Database = "mf_monitor",
  [int]$IntervalSec = 5
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $MysqlExe)) {
  throw "mysql.exe not found: $MysqlExe"
}

$SecurePwd = Read-Host "请输入 MySQL 密码(用户: $User)" -AsSecureString
$BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePwd)
$PlainPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

$query = @"
SELECT NOW() AS ts,
  (SELECT COUNT(*) FROM disaster_data) AS disaster_count,
  (SELECT COUNT(*) FROM speed_data) AS speed_count,
  (SELECT COUNT(*) FROM device_status) AS status_count;
"@

try {
  $env:MYSQL_PWD = $PlainPwd
  while ($true) {
    & $MysqlExe -h $DbHost -P $Port -u $User -D $Database -e $query
    Start-Sleep -Seconds $IntervalSec
  }
}
finally {
  Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}
