Param(
  [ValidateSet("dev", "test", "prod")]
  [string]$Env = "dev",
  [string]$EnvFile = "",
  [string]$MysqlExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysql.exe",
  [int]$ArchiveKeepDays = 180,
  [string[]]$Tables = @(
    "disaster_data_archive",
    "speed_data_archive",
    "alarms_archive",
    "alarm_notifications_archive",
    "audit_logs_archive"
  ),
  [switch]$DryRun
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
$dbName = $envMap['DB_NAME']
$dbUser = $envMap['DB_USER']
$dbPass = $envMap['DB_PASSWORD']

$mysqlBaseArgs = @("-h", $dbHost, "-P", $dbPort, "-u", $dbUser, "-p$dbPass", "-D", $dbName, "--default-character-set=utf8mb4")
$bt = [char]96

function Invoke-MySql {
  param([Parameter(Mandatory = $true)][string]$Sql)

  $errFile = Join-Path $env:TEMP ("mf_mysql_err_{0}_{1}.log" -f $PID, (Get-Random))
  $oldEap = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $raw = & $MysqlExe @mysqlBaseArgs -N -e $Sql 2> $errFile
    $exitCode = $LASTEXITCODE
    $stderr = if (Test-Path $errFile) { (Get-Content $errFile | Out-String).Trim() } else { "" }
  } finally {
    $ErrorActionPreference = $oldEap
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
  }

  $stdout = (($raw | Out-String).Trim())
  if ($exitCode -ne 0) {
    throw "MySQL execution failed.`nSQL: $Sql`nStdOut: $stdout`nStdErr: $stderr"
  }
  return $stdout
}

function Get-Count {
  param([Parameter(Mandatory = $true)][string]$Sql)

  $v = Invoke-MySql -Sql $Sql
  if ([string]::IsNullOrWhiteSpace($v)) { return 0 }
  return [int]$v
}

$cutoff = (Get-Date).AddDays(-1 * $ArchiveKeepDays)
$cutoffSql = $cutoff.ToString("yyyy-MM-dd HH:mm:ss")

if ($Tables.Count -eq 1 -and $Tables[0].Contains(',')) {
  $Tables = @($Tables[0].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

Write-Host "Starting archive cleanup..."
Write-Host "Cutoff(archive keep days=$ArchiveKeepDays): $cutoffSql"

$summary = @()

foreach ($table in $Tables) {
  $tableQuoted = "$bt$table$bt"

  $existSql = "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$dbName' AND table_name='$table';"
  $exists = Get-Count -Sql $existSql
  if ($exists -le 0) {
    Write-Warning "[$table] table not found, skip"
    continue
  }

  $colExistsSql = "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='$dbName' AND table_name='$table' AND column_name='archived_at';"
  $colExists = Get-Count -Sql $colExistsSql
  if ($colExists -le 0) {
    Write-Warning "[$table] archived_at column missing, skip"
    continue
  }

  $condition = "archived_at < '$cutoffSql'"
  $beforeSql = "SELECT COUNT(*) FROM $tableQuoted WHERE $condition;"
  $beforeCount = Get-Count -Sql $beforeSql

  if ($beforeCount -le 0) {
    Write-Host "[$table] no rows to clean"
    $summary += [pscustomobject]@{ table = $table; before = 0; deleted = 0; after = 0 }
    continue
  }

  if ($DryRun) {
    Write-Host "[$table] dry-run -> rows_to_delete=$beforeCount"
    $summary += [pscustomobject]@{ table = $table; before = $beforeCount; deleted = 0; after = $beforeCount }
    continue
  }

  $deleteSql = "DELETE FROM $tableQuoted WHERE $condition;"
  Invoke-MySql -Sql $deleteSql | Out-Null

  $afterCount = Get-Count -Sql $beforeSql
  $deleted = $beforeCount - $afterCount
  if ($deleted -lt 0) { $deleted = 0 }

  Write-Host "[$table] before=$beforeCount, deleted=$deleted, remaining_expired=$afterCount"
  $summary += [pscustomobject]@{ table = $table; before = $beforeCount; deleted = $deleted; after = $afterCount }
}

Write-Host "Cleanup summary:"
$summary | Format-Table -AutoSize | Out-String | Write-Host

if ($DryRun) {
  Write-Host "Done (dry-run)."
} else {
  Write-Host "Done."
}
