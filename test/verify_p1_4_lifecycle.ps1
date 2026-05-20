Param(
  [string]$EnvFile = ".env.dev",
  [string]$ApiBase = "http://127.0.0.1:8000",
  [string]$MysqlExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysql.exe",
  [int]$HotKeepDays = 30,
  [int]$ArchiveKeepDays = 30
)

$ErrorActionPreference = "Stop"
$PowerShellExe = Join-Path $PSHOME "powershell.exe"
if (-not (Test-Path $PowerShellExe)) { $PowerShellExe = "powershell.exe" }

if (-not (Test-Path $EnvFile)) {
  throw "Env file not found: $EnvFile"
}
if (-not (Test-Path $MysqlExe)) {
  throw "mysql.exe not found: $MysqlExe"
}

function As-Array {
  param([object]$Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Array]) { return $Value }
  return @($Value)
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
$apiKey = $envMap['API_KEY']
if (-not $apiKey) { throw "API_KEY missing in $EnvFile" }

$mysqlArgs = @("-h", $dbHost, "-P", $dbPort, "-u", $dbUser, "-p$dbPass", "-D", $dbName, "--default-character-set=utf8mb4")
$headers = @{ Authorization = "Bearer $apiKey" }
$bt = [char]96
$tsCol = "$bt" + "timestamp" + "$bt"

function Invoke-MySql {
  param([Parameter(Mandatory = $true)][string]$Sql)

  $errFile = Join-Path $env:TEMP ("mf_mysql_err_{0}_{1}.log" -f $PID, (Get-Random))
  $oldEap = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $raw = & $MysqlExe @mysqlArgs -N -e $Sql 2> $errFile
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

$tag = Get-Date -Format "HHmmss"
$aiboxId = "P14_$tag"
$camId = "CAM_$tag"
$oldDisasterId = "p14_old_$tag"
$newDisasterId = "p14_new_$tag"
$cleanupDisasterId = "p14_cleanup_$tag"
$oldTs = (Get-Date).AddDays(-40).ToString("yyyy-MM-dd HH:mm:ss")
$newTs = (Get-Date).AddMinutes(-2).ToString("yyyy-MM-dd HH:mm:ss")
$oldArchivedAt = (Get-Date).AddDays(-45).ToString("yyyy-MM-dd HH:mm:ss")

Write-Host "Test target => aibox_id=$aiboxId, cam_id=$camId"

try {
  Write-Host "[1/7] Seed hot+cold source data"
  $seedSql = @"
INSERT INTO disaster_data (disaster_id, aibox_id, cam_id, disaster_type, $tsCol, confidence, image_path)
VALUES
  ('$oldDisasterId', '$aiboxId', '$camId', 'flood', '$oldTs', 0.9500, 'https://storage.server/data/images/p14_old.jpg'),
  ('$newDisasterId', '$aiboxId', '$camId', 'flood', '$newTs', 0.9600, 'https://storage.server/data/images/p14_new.jpg');

INSERT INTO speed_data (aibox_id, cam_id, disaster_type, $tsCol, speed)
VALUES
  ('$aiboxId', '$camId', 'flood', '$oldTs', '[1.11,1.22,1.33,1.44]'),
  ('$aiboxId', '$camId', 'flood', '$newTs', '[1.21,1.32,1.43,1.54]');
"@
  Invoke-MySql -Sql $seedSql | Out-Null

  Write-Host "[2/7] Run cold archive"
  $archiveRun = Invoke-PsFile -ScriptPath ".\scripts\archive_cold_data.ps1" -Arguments @("-EnvFile", $EnvFile, "-HotKeepDays", "$HotKeepDays", "-Tables", "disaster_data,speed_data")
  if ($archiveRun.ExitCode -ne 0) {
    Write-Host "archive stderr:"
    $archiveRun.StdErr | ForEach-Object { Write-Host "  $_" }
    throw "archive_cold_data.ps1 failed. ExitCode=$($archiveRun.ExitCode)"
  }

  Write-Host "[3/7] Verify archive result"
  $srcOldDisaster = Get-Count -Sql "SELECT COUNT(*) FROM disaster_data WHERE disaster_id='$oldDisasterId';"
  $srcNewDisaster = Get-Count -Sql "SELECT COUNT(*) FROM disaster_data WHERE disaster_id='$newDisasterId';"
  $archOldDisaster = Get-Count -Sql "SELECT COUNT(*) FROM disaster_data_archive WHERE disaster_id='$oldDisasterId';"

  $srcOldSpeed = Get-Count -Sql "SELECT COUNT(*) FROM speed_data WHERE aibox_id='$aiboxId' AND cam_id='$camId' AND $tsCol='$oldTs';"
  $srcNewSpeed = Get-Count -Sql "SELECT COUNT(*) FROM speed_data WHERE aibox_id='$aiboxId' AND cam_id='$camId' AND $tsCol='$newTs';"
  $archOldSpeed = Get-Count -Sql "SELECT COUNT(*) FROM speed_data_archive WHERE aibox_id='$aiboxId' AND cam_id='$camId' AND $tsCol='$oldTs';"

  if ($srcOldDisaster -ne 0 -or $archOldDisaster -ne 1) {
    throw "Archive verify failed(disaster_data): src_old=$srcOldDisaster, arch_old=$archOldDisaster"
  }
  if ($srcNewDisaster -ne 1) {
    throw "Archive verify failed(disaster_data): src_new should remain 1, got $srcNewDisaster"
  }
  if ($srcOldSpeed -ne 0 -or $archOldSpeed -ne 1) {
    throw "Archive verify failed(speed_data): src_old=$srcOldSpeed, arch_old=$archOldSpeed"
  }
  if ($srcNewSpeed -ne 1) {
    throw "Archive verify failed(speed_data): src_new should remain 1, got $srcNewSpeed"
  }
  Write-Host "  archive move checks passed"

  Write-Host "[4/7] Verify online API query unaffected"
  $startIso = [System.Uri]::EscapeDataString((Get-Date).ToUniversalTime().AddMinutes(-20).ToString("yyyy-MM-ddTHH:mm:ssZ"))
  $endIso = [System.Uri]::EscapeDataString((Get-Date).ToUniversalTime().AddMinutes(1).ToString("yyyy-MM-ddTHH:mm:ssZ"))
  $url = "$ApiBase/api/classification?start_time=$startIso&end_time=$endIso&aibox_id=$aiboxId&cam_id=$camId"
  $apiRaw = Invoke-RestMethod $url -Headers $headers -Method Get
  $apiRows = @(As-Array $apiRaw)
  $matchedNew = @($apiRows | Where-Object { $_.disaster_id -eq $newDisasterId })
  if ($matchedNew.Count -ne 1) {
    throw "Online query verify failed: expected to find new disaster_id=$newDisasterId exactly once, got $($matchedNew.Count)"
  }
  Write-Host "  online query check passed"

  Write-Host "[5/7] Seed one expired archive row"
  $seedArchiveSql = @"
INSERT INTO disaster_data_archive
  (disaster_id, aibox_id, cam_id, disaster_type, $tsCol, confidence, image_path, created_at, archived_at)
VALUES
  ('$cleanupDisasterId', '$aiboxId', '$camId', 'flood', '$oldTs', 0.9100, 'https://storage.server/data/images/p14_cleanup.jpg', '$oldTs', '$oldArchivedAt');
"@
  Invoke-MySql -Sql $seedArchiveSql | Out-Null
  $cleanupBefore = Get-Count -Sql "SELECT COUNT(*) FROM disaster_data_archive WHERE disaster_id='$cleanupDisasterId';"
  if ($cleanupBefore -ne 1) {
    throw "Seed cleanup row failed, count=$cleanupBefore"
  }

  Write-Host "[6/7] Run archive cleanup"
  $cleanupRun = Invoke-PsFile -ScriptPath ".\scripts\cleanup_archive_data.ps1" -Arguments @("-EnvFile", $EnvFile, "-ArchiveKeepDays", "$ArchiveKeepDays", "-Tables", "disaster_data_archive")
  if ($cleanupRun.ExitCode -ne 0) {
    Write-Host "cleanup stderr:"
    $cleanupRun.StdErr | ForEach-Object { Write-Host "  $_" }
    throw "cleanup_archive_data.ps1 failed. ExitCode=$($cleanupRun.ExitCode)"
  }

  Write-Host "[7/7] Verify cleanup result"
  $cleanupAfter = Get-Count -Sql "SELECT COUNT(*) FROM disaster_data_archive WHERE disaster_id='$cleanupDisasterId';"
  $oldStillExists = Get-Count -Sql "SELECT COUNT(*) FROM disaster_data_archive WHERE disaster_id='$oldDisasterId';"
  if ($cleanupAfter -ne 0) {
    throw "Cleanup failed: expired archive row still exists(count=$cleanupAfter)"
  }
  if ($oldStillExists -ne 1) {
    throw "Cleanup affected non-expired archived row unexpectedly(count=$oldStillExists)"
  }

  Write-Host "PASS: P1-4 lifecycle baseline works"
}
finally {
  $cleanupSql = @"
DELETE FROM disaster_data WHERE disaster_id IN ('$oldDisasterId', '$newDisasterId', '$cleanupDisasterId');
DELETE FROM disaster_data_archive WHERE disaster_id IN ('$oldDisasterId', '$newDisasterId', '$cleanupDisasterId');
DELETE FROM speed_data WHERE aibox_id='$aiboxId' AND cam_id='$camId';
DELETE FROM speed_data_archive WHERE aibox_id='$aiboxId' AND cam_id='$camId';
"@
  try {
    Invoke-MySql -Sql $cleanupSql | Out-Null
  } catch { }
}




