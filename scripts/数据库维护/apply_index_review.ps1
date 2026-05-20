Param(
  [string]$MysqlExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysql.exe",
  [string]$User = "Evil_Pidan_King",
  [string]$DbHost = "127.0.0.1",
  [int]$Port = 3306,
  [string]$Database = "mf_monitor"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $MysqlExe)) {
  throw "mysql.exe not found: $MysqlExe"
}

function Exec-MySql {
  param([string]$Sql)
  & $MysqlExe -h $DbHost -P $Port -u $User -D $Database -N -e $Sql
}

function Ensure-Index {
  param(
    [string]$TableName,
    [string]$IndexName,
    [string]$IndexCols
  )

  $checkSql = "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='$Database' AND table_name='$TableName' AND index_name='$IndexName';"
  $exists = [int](Exec-MySql -Sql $checkSql)

  if ($exists -eq 0) {
    $createSql = "ALTER TABLE $TableName ADD INDEX $IndexName ($IndexCols);"
    Exec-MySql -Sql $createSql | Out-Null
    Write-Host "[ADD] $TableName.$IndexName ($IndexCols)"
  } else {
    Write-Host "[OK ] $TableName.$IndexName 已存在"
  }
}

function Drop-Index-IfExists {
  param(
    [string]$TableName,
    [string]$IndexName
  )

  $checkSql = "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='$Database' AND table_name='$TableName' AND index_name='$IndexName';"
  $exists = [int](Exec-MySql -Sql $checkSql)

  if ($exists -gt 0) {
    $dropSql = "ALTER TABLE $TableName DROP INDEX $IndexName;"
    Exec-MySql -Sql $dropSql | Out-Null
    Write-Host "[DROP] $TableName.$IndexName"
  } else {
    Write-Host "[SKIP] $TableName.$IndexName 不存在"
  }
}

$SecurePwd = Read-Host "请输入 MySQL 密码(用户: $User)" -AsSecureString
$BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePwd)
$PlainPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

try {
  $env:MYSQL_PWD = $PlainPwd

  Write-Host "开始索引复核与优化..."

  Ensure-Index -TableName "disaster_data" -IndexName "idx_disaster_device_time" -IndexCols "aibox_id, cam_id, timestamp"
  Ensure-Index -TableName "disaster_data" -IndexName "idx_disaster_aibox_time" -IndexCols "aibox_id, timestamp"

  Ensure-Index -TableName "speed_data" -IndexName "idx_speed_device_time" -IndexCols "aibox_id, cam_id, timestamp"
  Ensure-Index -TableName "speed_data" -IndexName "idx_speed_aibox_time" -IndexCols "aibox_id, timestamp"

  # 清理冗余旧索引，减少写入开销
  Drop-Index-IfExists -TableName "disaster_data" -IndexName "idx_disaster_device"
  Drop-Index-IfExists -TableName "speed_data" -IndexName "idx_speed_device"

  Write-Host "索引复核完成。"

  Write-Host "当前关键索引(disaster_data):"
  Exec-MySql -Sql "SHOW INDEX FROM disaster_data;"
  Write-Host "当前关键索引(speed_data):"
  Exec-MySql -Sql "SHOW INDEX FROM speed_data;"
}
finally {
  Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}
