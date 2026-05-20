Param(
  [Parameter(Mandatory = $true)]
  [string]$BackupFile,
  [ValidateSet("dev", "test", "prod")]
  [string]$Env = "dev",
  [string]$EnvFile = "",
  [string]$MysqlExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysql.exe",
  [string]$TargetDatabase = "",
  [switch]$DropAndRecreate,
  [string]$AdminUser = "",
  [string]$AdminPassword = ""
)

$ErrorActionPreference = "Stop"
$PowerShellExe = Join-Path $PSHOME "powershell.exe"
if (-not (Test-Path $PowerShellExe)) { $PowerShellExe = "powershell.exe" }

if (-not $EnvFile) {
  $candidate = ".env.$Env"
  if (Test-Path $candidate) { $EnvFile = $candidate } else { $EnvFile = ".env" }
}

& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check_env.ps1 -EnvFile $EnvFile -Mode backend

if (-not (Test-Path $MysqlExe)) {
  throw "mysql.exe not found: $MysqlExe"
}
if (-not (Test-Path $BackupFile)) {
  throw "Backup file not found: $BackupFile"
}

$envMap = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
  $parts = $_.Split('=', 2)
  $envMap[$parts[0].Trim()] = $parts[1]
}

$dbHost = $envMap['DB_HOST']
$dbPort = [int]$envMap['DB_PORT']
$dbUser = $envMap['DB_USER']
$dbPass = $envMap['DB_PASSWORD']
$dbName = if ($TargetDatabase) { $TargetDatabase } else { $envMap['DB_NAME'] }

$adminUser = if ($AdminUser) { $AdminUser } else { $dbUser }
$adminPass = if ($AdminUser) { $AdminPassword } else { $dbPass }

$dbEsc = $dbName.Replace('`', '``')

if ($DropAndRecreate) {
  Write-Host "Dropping and recreating target DB: $dbName"
  $sql = "DROP DATABASE IF EXISTS ``$dbEsc``; CREATE DATABASE ``$dbEsc`` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
  & $MysqlExe -h $dbHost -P $dbPort -u $adminUser "-p$adminPass" -e $sql
  if ($LASTEXITCODE -ne 0) {
    throw "Drop/Recreate failed. Use admin account, e.g. -AdminUser root -AdminPassword <pwd>. ExitCode=$LASTEXITCODE"
  }
} else {
  $sql = "CREATE DATABASE IF NOT EXISTS ``$dbEsc`` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
  & $MysqlExe -h $dbHost -P $dbPort -u $adminUser "-p$adminPass" -e $sql
  if ($LASTEXITCODE -ne 0) {
    throw "Create DB failed. Use admin account, e.g. -AdminUser root -AdminPassword <pwd>. ExitCode=$LASTEXITCODE"
  }
}

# Ensure app DB user can read drill DB for verification queries.
$grantSql = "GRANT ALL PRIVILEGES ON ``$dbEsc``.* TO '$dbUser'@'%'; FLUSH PRIVILEGES;"
& $MysqlExe -h $dbHost -P $dbPort -u $adminUser "-p$adminPass" -e $grantSql
if ($LASTEXITCODE -ne 0) {
  throw "Grant privileges failed for user '$dbUser' on '$dbName'. ExitCode=$LASTEXITCODE"
}
$sourcePath = (Resolve-Path $BackupFile).Path
Write-Host "Restoring backup into $dbName ..."

$importProc = Start-Process -FilePath $MysqlExe `
  -ArgumentList @("-h", $dbHost, "-P", $dbPort, "-u", $adminUser, "-p$adminPass", "-D", $dbName, "--default-character-set=utf8mb4") `
  -RedirectStandardInput $sourcePath `
  -NoNewWindow -Wait -PassThru

if ($importProc.ExitCode -ne 0) { throw "Restore failed. ExitCode=$($importProc.ExitCode)" }

Write-Host "Restore completed."
Write-Host "RESTORED_DB=$dbName"
Write-Host "RESTORE_SOURCE=$sourcePath"



