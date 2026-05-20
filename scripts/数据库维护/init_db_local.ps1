Param(
  [string]$MysqlExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysql.exe",
  [string]$User = "root",
  [string]$DbHost = "127.0.0.1",
  [int]$Port = 3306,
  [string]$SqlFile = ".\sql\init.sql"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $MysqlExe)) {
  throw "mysql.exe not found: $MysqlExe"
}

if (-not (Test-Path $SqlFile)) {
  throw "SQL file not found: $SqlFile"
}

$SecurePwd = Read-Host "请输入 MySQL 密码(用户: $User)" -AsSecureString
$BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePwd)
$PlainPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

try {
  $env:MYSQL_PWD = $PlainPwd
  & $MysqlExe -h $DbHost -P $Port -u $User --default-character-set=utf8mb4 -e "SOURCE $SqlFile"
  & $MysqlExe -h $DbHost -P $Port -u $User -e "SHOW TABLES IN mf_monitor;"
  Write-Host "数据库初始化完成: mf_monitor"
}
finally {
  Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}
