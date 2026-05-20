Param(
  [string]$MysqlExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysql.exe",
  [string]$User = "Evil_Pidan_King",
  [string]$DbHost = "127.0.0.1",
  [int]$Port = 3306,
  [string]$Database = "mf_monitor",
  [int]$WaitSec = 15
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $MysqlExe)) {
  throw "mysql.exe not found: $MysqlExe"
}

function Get-SpeedStat {
  param(
    [string]$MysqlExe,
    [string]$DbHost,
    [int]$Port,
    [string]$User,
    [string]$Database
  )

  $sql = "SELECT (SELECT COUNT(*) FROM speed_data) AS speed_count, (SELECT IFNULL(MAX(``timestamp``), '1970-01-01 00:00:00') FROM speed_data) AS last_ts;"

  $raw = & $MysqlExe -h $DbHost -P $Port -u $User -D $Database -N -e $sql
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return [pscustomobject]@{ count = 0; last_ts = '1970-01-01 00:00:00' }
  }

  $parts = $raw.Trim() -split "\s+"
  $count = [int]$parts[0]
  $ts = if ($parts.Length -gt 1) { ($parts[1..($parts.Length - 1)] -join " ") } else { "1970-01-01 00:00:00" }

  return [pscustomobject]@{
    count = $count
    last_ts = $ts
  }
}

$SecurePwd = Read-Host "请输入 MySQL 密码(用户: $User)" -AsSecureString
$BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePwd)
$PlainPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

try {
  $env:MYSQL_PWD = $PlainPwd

  Write-Host "[1/3] 读取 speed_data 当前状态..."
  $before = Get-SpeedStat -MysqlExe $MysqlExe -DbHost $DbHost -Port $Port -User $User -Database $Database
  Write-Host "before => count=$($before.count), last_ts=$($before.last_ts)"

  Write-Host "[2/3] 等待 $WaitSec 秒，请确保模拟器正在发送 speed..."
  Start-Sleep -Seconds $WaitSec

  Write-Host "[3/3] 再次读取 speed_data 状态..."
  $after = Get-SpeedStat -MysqlExe $MysqlExe -DbHost $DbHost -Port $Port -User $User -Database $Database
  Write-Host "after  => count=$($after.count), last_ts=$($after.last_ts)"

  if ($after.count -gt $before.count) {
    Write-Host "验证通过: speed_data 计数增长，写库正常。"
  } else {
    Write-Host "验证未通过: speed_data 计数未增长，请检查模拟器/后端日志。"
  }
}
finally {
  Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}
