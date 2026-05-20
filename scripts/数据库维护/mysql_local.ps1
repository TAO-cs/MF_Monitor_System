Param(
  [string]$MysqlExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysql.exe",
  [string]$DbHost = "127.0.0.1",
  [int]$Port = 3306,
  [string]$User = "Evil_Pidan_King",
  [string]$Database = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $MysqlExe)) {
  throw "mysql.exe not found: $MysqlExe"
}

$args = @("-h", $DbHost, "-P", "$Port", "-u", $User, "-p")
if ($Database) { $args += @("-D", $Database) }

Write-Host "Connecting LOCAL MySQL: ${DbHost}:${Port}, user=${User}" -ForegroundColor Cyan
& $MysqlExe @args
