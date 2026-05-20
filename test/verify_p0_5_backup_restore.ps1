Param(
  [ValidateSet("dev", "test", "prod")]
  [string]$Env = "dev",
  [string]$EnvFile = "",
  [string]$MysqlExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysql.exe",
  [string]$AdminUser = "root",
  [string]$AdminPassword = "root123"
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
$dbName = $envMap['DB_NAME']
$drillDb = "${dbName}_drill"

function Get-Counts([string]$Database) {
  $sql = "SELECT (SELECT COUNT(*) FROM disaster_data),(SELECT COUNT(*) FROM speed_data),(SELECT COUNT(*) FROM device_status),(SELECT COUNT(*) FROM device_location);"
  $raw = & $MysqlExe -h $dbHost -P $dbPort -u $dbUser "-p$dbPass" -D $Database -N -e $sql
  if (-not $raw) { throw "Failed to read counts from $Database" }
  $parts = $raw.Trim() -split "\s+"
  return [pscustomobject]@{
    disaster = [int]$parts[0]
    speed = [int]$parts[1]
    status = [int]$parts[2]
    location = [int]$parts[3]
  }
}

function Invoke-PsFile {
  param(
    [string]$ScriptPath,
    [string[]]$Arguments
  )
  $outFile = Join-Path $env:TEMP ("mf_ps_out_{0}_{1}.log" -f $PID, (Get-Random))
  $errFile = Join-Path $env:TEMP ("mf_ps_err_{0}_{1}.log" -f $PID, (Get-Random))
  try {
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $Arguments
    $p = Start-Process -FilePath $PowerShellExe -ArgumentList $argList -WorkingDirectory (Get-Location).Path -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $stdout = if (Test-Path $outFile) { Get-Content $outFile } else { @() }
    $stderr = if (Test-Path $errFile) { Get-Content $errFile } else { @() }
    return [pscustomobject]@{
      ExitCode = $p.ExitCode
      StdOut = @($stdout)
      StdErr = @($stderr)
    }
  } finally {
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "[1/4] Create backup"
$backupRun = Invoke-PsFile -ScriptPath ".\scripts\backup_db.ps1" -Arguments @("-Env", $Env, "-EnvFile", $EnvFile)
if ($backupRun.ExitCode -ne 0) {
  Write-Host "backup stderr:"
  $backupRun.StdErr | ForEach-Object { Write-Host "  $_" }
  throw "backup_db.ps1 failed. ExitCode=$($backupRun.ExitCode)"
}
$backupLines = @($backupRun.StdOut + $backupRun.StdErr)
$backupLine = $backupLines | Where-Object { $_ -match '^BACKUP_FILE=' } | Select-Object -First 1

if ($backupLine) {
  $backupFile = $backupLine.Substring(12)
} else {
  $pattern = "${dbName}_${Env}_*.sql"
  $latest = Get-ChildItem "backups\\mysql" -Filter $pattern -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if (-not $latest) {
    Write-Host "backup output(raw):"
    $backupLines | ForEach-Object { Write-Host "  $_" }
    throw "Cannot parse BACKUP_FILE and no fallback file found in backups/mysql"
  }
  $backupFile = $latest.FullName
  Write-Warning "BACKUP_FILE parse failed; fallback to latest file: $backupFile"
}
Write-Host "  backup_file=$backupFile"

Write-Host "[2/4] Read source counts"
$sourceCounts = Get-Counts -Database $dbName
Write-Host "  source => disaster=$($sourceCounts.disaster), speed=$($sourceCounts.speed), status=$($sourceCounts.status), location=$($sourceCounts.location)"

Write-Host "[3/4] Restore to drill DB: $drillDb"
$restoreRun = Invoke-PsFile -ScriptPath ".\scripts\restore_db.ps1" -Arguments @("-BackupFile", $backupFile, "-Env", $Env, "-EnvFile", $EnvFile, "-TargetDatabase", $drillDb, "-DropAndRecreate", "-AdminUser", $AdminUser, "-AdminPassword", $AdminPassword)
if ($restoreRun.ExitCode -ne 0) {
  Write-Host "restore stderr:"
  $restoreRun.StdErr | ForEach-Object { Write-Host "  $_" }
  throw "restore_db.ps1 failed. ExitCode=$($restoreRun.ExitCode)"
}
$drillCounts = Get-Counts -Database $drillDb
Write-Host "  drill  => disaster=$($drillCounts.disaster), speed=$($drillCounts.speed), status=$($drillCounts.status), location=$($drillCounts.location)"

Write-Host "[4/4] Compare"
$ok = (
  $sourceCounts.disaster -eq $drillCounts.disaster -and
  $sourceCounts.speed -eq $drillCounts.speed -and
  $sourceCounts.status -eq $drillCounts.status -and
  $sourceCounts.location -eq $drillCounts.location
)

if ($ok) {
  Write-Host "PASS: backup/restore drill verified."
} else {
  throw "FAIL: counts mismatch after restore drill"
}
