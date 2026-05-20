Param(
  [ValidateSet("dev", "test", "prod")]
  [string]$Env = "dev",
  [string]$EnvFile = "",
  [string]$MysqldumpExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysqldump.exe",
  [string]$OutputDir = "backups\mysql",
  [int]$KeepDays = 7
)

$ErrorActionPreference = "Stop"
$PowerShellExe = Join-Path $PSHOME "powershell.exe"
if (-not (Test-Path $PowerShellExe)) { $PowerShellExe = "powershell.exe" }

if (-not $EnvFile) {
  $candidate = ".env.$Env"
  if (Test-Path $candidate) { $EnvFile = $candidate } else { $EnvFile = ".env" }
}

& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check_env.ps1 -EnvFile $EnvFile -Mode backend

if (-not (Test-Path $MysqldumpExe)) {
  throw "mysqldump.exe not found: $MysqldumpExe"
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

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$backupFile = Join-Path $OutputDir ("{0}_{1}_{2}.sql" -f $dbName, $Env, $ts)
$metaFile = Join-Path $OutputDir ("{0}_{1}_{2}.meta.txt" -f $dbName, $Env, $ts)

Write-Host "Starting backup..."
& $MysqldumpExe `
  -h $dbHost `
  -P $dbPort `
  -u $dbUser `
  "-p$dbPass" `
  --single-transaction `
  --skip-lock-tables `
  --no-tablespaces `
  --set-gtid-purged=OFF `
  --default-character-set=utf8mb4 `
  $dbName `
  --result-file=$backupFile

if ($LASTEXITCODE -ne 0) {
  throw "Backup failed. ExitCode=$LASTEXITCODE"
}
if (-not (Test-Path $backupFile) -or (Get-Item $backupFile).Length -le 0) {
  throw "Backup failed: output file is missing or empty ($backupFile)"
}

@(
  "timestamp=$ts",
  "env=$Env",
  "env_file=$EnvFile",
  "db_host=$dbHost",
  "db_port=$dbPort",
  "db_name=$dbName",
  "db_user=$dbUser",
  "backup_file=$backupFile"
) | Set-Content -Encoding Ascii $metaFile

if ($KeepDays -ge 0) {
  $deadline = (Get-Date).AddDays(-1 * $KeepDays)
  Get-ChildItem $OutputDir -File | Where-Object { $_.LastWriteTime -lt $deadline } | Remove-Item -Force
}

Write-Host "Backup completed."
Write-Host "BACKUP_FILE=$backupFile"
Write-Host "META_FILE=$metaFile"
Write-Output "BACKUP_FILE=$backupFile"
Write-Output "META_FILE=$metaFile"

