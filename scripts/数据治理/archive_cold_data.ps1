Param(
  [ValidateSet("dev", "test", "prod")]
  [string]$Env = "dev",
  [string]$EnvFile = "",
  [string]$MysqlExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysql.exe",
  [int]$HotKeepDays = 30,
  [string[]]$Tables = @("disaster_data", "speed_data", "alarms", "alarm_notifications", "audit_logs"),
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

$cutoff = (Get-Date).AddDays(-1 * $HotKeepDays)
$cutoffSql = $cutoff.ToString("yyyy-MM-dd HH:mm:ss")

if ($Tables.Count -eq 1 -and $Tables[0].Contains(',')) {
  $Tables = @($Tables[0].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$specMap = @{
  "disaster_data" = @{ TimeColumn = "$bt" + "timestamp" + "$bt"; Extra = "" }
  "speed_data" = @{ TimeColumn = "$bt" + "timestamp" + "$bt"; Extra = "" }
  "alarms" = @{ TimeColumn = "triggered_at"; Extra = "t.status='closed'" }
  "alarm_notifications" = @{ TimeColumn = "created_at"; Extra = "(t.next_retry_at IS NULL OR t.next_retry_at < '$cutoffSql')" }
  "audit_logs" = @{ TimeColumn = "created_at"; Extra = "" }
}

Write-Host "Starting cold-data archive..."
Write-Host "Cutoff(keep hot days=$HotKeepDays): $cutoffSql"

$summary = @()

foreach ($table in $Tables) {
  if (-not $specMap.ContainsKey($table)) {
    Write-Warning "Unsupported table '$table', skip"
    continue
  }

  $spec = $specMap[$table]
  $archiveTable = "${table}_archive"

  $srcQuoted = "$bt$table$bt"
  $archQuoted = "$bt$archiveTable$bt"

  Invoke-MySql -Sql "CREATE TABLE IF NOT EXISTS $archQuoted LIKE $srcQuoted;" | Out-Null

  $colExistsSql = "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='$dbName' AND table_name='$archiveTable' AND column_name='archived_at';"
  $colExists = Get-Count -Sql $colExistsSql
  if ($colExists -le 0) {
    Invoke-MySql -Sql "ALTER TABLE $archQuoted ADD COLUMN archived_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;" | Out-Null
  }

  $condition = "t.$($spec.TimeColumn) < '$cutoffSql'"
  if (-not [string]::IsNullOrWhiteSpace($spec.Extra)) {
    $condition = "$condition AND $($spec.Extra)"
  }

  $beforeSql = "SELECT COUNT(*) FROM $srcQuoted t WHERE $condition;"
  $beforeCount = Get-Count -Sql $beforeSql

  if ($beforeCount -le 0) {
    Write-Host "[$table] no cold rows"
    $summary += [pscustomobject]@{ table = $table; before = 0; moved = 0; after = 0 }
    continue
  }

  if ($DryRun) {
    Write-Host "[$table] dry-run -> cold rows=$beforeCount"
    $summary += [pscustomobject]@{ table = $table; before = $beforeCount; moved = 0; after = $beforeCount }
    continue
  }

  $moveSql = @"
START TRANSACTION;
INSERT IGNORE INTO $archQuoted
SELECT t.*, NOW() AS archived_at
FROM $srcQuoted t
WHERE $condition;
DELETE t
FROM $srcQuoted t
INNER JOIN $archQuoted a ON a.id = t.id
WHERE $condition;
COMMIT;
"@
  Invoke-MySql -Sql $moveSql | Out-Null

  $afterCount = Get-Count -Sql $beforeSql
  $moved = $beforeCount - $afterCount
  if ($moved -lt 0) { $moved = 0 }

  Write-Host "[$table] before=$beforeCount, moved=$moved, remaining_cold=$afterCount"
  $summary += [pscustomobject]@{ table = $table; before = $beforeCount; moved = $moved; after = $afterCount }
}

Write-Host "Archive summary:"
$summary | Format-Table -AutoSize | Out-String | Write-Host

if ($DryRun) {
  Write-Host "Done (dry-run)."
} else {
  Write-Host "Done."
}
