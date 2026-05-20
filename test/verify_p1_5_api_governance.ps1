Param(
  [string]$EnvFile = ".env.dev",
  [string]$ApiBase = "http://127.0.0.1:8000",
  [string]$MysqlExe = "D:\MySQL\mysql-8.0.45-winx64\bin\mysql.exe",
  [int]$RateLimitProbeMaxRequests = 240
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

$envMap = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
  $parts = $_.Split('=', 2)
  $envMap[$parts[0].Trim()] = $parts[1]
}

$apiKey = $envMap['API_KEY']
if (-not $apiKey) { throw "API_KEY missing in $EnvFile" }

$dbHost = $envMap['DB_HOST']
$dbPort = [int]$envMap['DB_PORT']
$dbName = $envMap['DB_NAME']
$dbUser = $envMap['DB_USER']
$dbPass = $envMap['DB_PASSWORD']
$rateLimitEnabled = ($envMap['RATE_LIMIT_ENABLED'] -ne '0' -and $envMap['RATE_LIMIT_ENABLED'] -ne 'false' -and $envMap['RATE_LIMIT_ENABLED'] -ne 'False')
$idempotencyEnabled = ($envMap['IDEMPOTENCY_ENABLED'] -ne '0' -and $envMap['IDEMPOTENCY_ENABLED'] -ne 'false' -and $envMap['IDEMPOTENCY_ENABLED'] -ne 'False')

$mysqlArgs = @("-h", $dbHost, "-P", $dbPort, "-u", $dbUser, "-p$dbPass", "-D", $dbName, "--default-character-set=utf8mb4")
$authHeaders = @{ Authorization = "Bearer $apiKey" }
$tag = Get-Date -Format "HHmmss"
$aiboxId = "P15_$tag"
$camId = "CAM_$tag"
$ruleCode = "p15_rule_$tag"
$idemKey = "p15-idem-$tag"
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

function As-Array {
  param([object]$Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Array]) { return $Value }
  return @($Value)
}
function Get-HttpErrorInfo {
  param([Parameter(Mandatory = $true)]$ErrorRecord)

  $response = $ErrorRecord.Exception.Response
  if ($null -eq $response) {
    throw $ErrorRecord
  }

  $status = [int]$response.StatusCode.value__
  $body = ""

  $errorDetailsText = [string]$ErrorRecord.ErrorDetails.Message
  if (-not [string]::IsNullOrWhiteSpace($errorDetailsText)) {
    $body = $errorDetailsText.Trim()
  } else {
    try {
      $stream = $response.GetResponseStream()
      if ($null -ne $stream) {
        $reader = New-Object System.IO.StreamReader($stream)
        $body = $reader.ReadToEnd()
        $reader.Close()
      }
    } catch {
      $body = ""
    }
  }

  $obj = $null
  if (-not [string]::IsNullOrWhiteSpace($body)) {
    try {
      $obj = $body | ConvertFrom-Json
    } catch {
      $obj = $null
    }
  }

  return @{
    status = $status
    body = $body
    obj = $obj
  }
}

Write-Host "[1/6] Seed data for pagination test"
$seedSql = @"
INSERT INTO disaster_data (disaster_id, aibox_id, cam_id, disaster_type, $tsCol, confidence, image_path)
VALUES
  ('p15_cls_${tag}_1', '$aiboxId', '$camId', 'flood', DATE_SUB(NOW(), INTERVAL 3 MINUTE), 0.91, 'https://storage.server/data/images/p15_1.jpg'),
  ('p15_cls_${tag}_2', '$aiboxId', '$camId', 'flood', DATE_SUB(NOW(), INTERVAL 2 MINUTE), 0.92, 'https://storage.server/data/images/p15_2.jpg'),
  ('p15_cls_${tag}_3', '$aiboxId', '$camId', 'flood', DATE_SUB(NOW(), INTERVAL 1 MINUTE), 0.93, 'https://storage.server/data/images/p15_3.jpg');
"@
Invoke-MySql -Sql $seedSql | Out-Null

try {
  Write-Host "[2/6] Verify pagination format"
  $page1Url = "$ApiBase/api/classification?paginate=true&page=1&page_size=2&aibox_id=$aiboxId&cam_id=$camId"
  $page2Url = "$ApiBase/api/classification?paginate=true&page=2&page_size=2&aibox_id=$aiboxId&cam_id=$camId"

  $p1 = Invoke-RestMethod $page1Url -Headers $authHeaders -Method Get
  $p2 = Invoke-RestMethod $page2Url -Headers $authHeaders -Method Get

  if (-not ($p1.PSObject.Properties.Name -contains 'items' -and $p1.PSObject.Properties.Name -contains 'total')) {
    throw "pagination response missing items/total"
  }

  $items1 = @(As-Array $p1.items)
  $items2 = @(As-Array $p2.items)

  if ($p1.page -ne 1 -or $p1.page_size -ne 2) {
    throw "unexpected page/page_size in pagination response"
  }
  if ($p1.total -lt 3) {
    throw "unexpected total for pagination test: $($p1.total)"
  }
  if ($items1.Count -ne 2) {
    throw "page1 expected 2 items, got $($items1.Count)"
  }
  if ($items2.Count -lt 1) {
    throw "page2 expected at least 1 item, got $($items2.Count)"
  }
  Write-Host "  pagination ok: total=$($p1.total), page1=$($items1.Count), page2=$($items2.Count)"

  Write-Host "[3/6] Verify unified error schema (401)"
  try {
    Invoke-WebRequest "$ApiBase/api/device_status" -Method Get -UseBasicParsing | Out-Null
    throw "expected 401 but got success"
  } catch {
    $info = Get-HttpErrorInfo -ErrorRecord $_
    if ($info.status -ne 401) {
      throw "expected 401, got $($info.status)"
    }

    $obj = $info.obj
    if (-not $obj.code -or -not $obj.message -or -not $obj.request_id) {
      throw "error schema missing code/message/request_id, raw=$($info.body)"
    }
    if ($obj.code -ne 'AUTH_MISSING_HEADER') {
      throw "expected AUTH_MISSING_HEADER, got $($obj.code)"
    }
    Write-Host "  unified error ok: code=$($obj.code)"
  }

  Write-Host "[4/6] Verify idempotency for write API"
  if (-not $idempotencyEnabled) {
    Write-Host "  SKIP: IDEMPOTENCY_ENABLED is off"
  } else {
    $body1 = @{
      rule_code = $ruleCode
      name = "P1-5 idempotent rule $tag"
      event_type = "classification"
      severity = "high"
      enabled = $true
      cooldown_seconds = 60
      condition_json = @{ disaster_type = "flood"; min_confidence = 0.95 }
    } | ConvertTo-Json -Compress

    $idemHeaders = @{ Authorization = "Bearer $apiKey"; "Idempotency-Key" = $idemKey }

    $r1 = Invoke-WebRequest "$ApiBase/api/alarm_rules" -Method Post -Headers $idemHeaders -ContentType "application/json" -Body $body1 -UseBasicParsing
    $o1 = $r1.Content | ConvertFrom-Json

    $r2 = Invoke-WebRequest "$ApiBase/api/alarm_rules" -Method Post -Headers $idemHeaders -ContentType "application/json" -Body $body1 -UseBasicParsing
    $o2 = $r2.Content | ConvertFrom-Json

    if ($o1.id -ne $o2.id) {
      throw "idempotent replay should return same id, got $($o1.id) vs $($o2.id)"
    }

    $rules = @(As-Array (Invoke-RestMethod "$ApiBase/api/alarm_rules?rule_code=$ruleCode" -Headers $authHeaders -Method Get))
    if ($rules.Count -ne 1) {
      throw "idempotency failed: expected exactly 1 rule row, got $($rules.Count)"
    }

    $bodyConflict = @{
      rule_code = $ruleCode
      name = "P1-5 idempotent rule changed $tag"
      event_type = "classification"
      severity = "high"
      enabled = $true
      cooldown_seconds = 120
      condition_json = @{ disaster_type = "flood"; min_confidence = 0.99 }
    } | ConvertTo-Json -Compress

    try {
      Invoke-WebRequest "$ApiBase/api/alarm_rules" -Method Post -Headers $idemHeaders -ContentType "application/json" -Body $bodyConflict -UseBasicParsing | Out-Null
      throw "expected 409 for idempotency key conflict"
    } catch {
      $info = Get-HttpErrorInfo -ErrorRecord $_
      if ($info.status -ne 409) {
        throw "expected 409 for idempotency conflict, got $($info.status)"
      }
      $obj = $info.obj
      if ($obj.code -ne 'IDEMPOTENCY_KEY_REUSE_CONFLICT') {
        throw "expected IDEMPOTENCY_KEY_REUSE_CONFLICT, got $($obj.code)"
      }
    }

    Write-Host "  idempotency ok"
  }

  Write-Host "[5/6] Verify rate limiting (429)"
  if (-not $rateLimitEnabled) {
    Write-Host "  SKIP: RATE_LIMIT_ENABLED is off"
  } else {
    $hit429 = $false
    $hitCode = ''

    for ($i = 0; $i -lt $RateLimitProbeMaxRequests; $i++) {
      try {
        Invoke-WebRequest "$ApiBase/api/device_status" -Method Get -Headers $authHeaders -UseBasicParsing | Out-Null
      } catch {
        $info = Get-HttpErrorInfo -ErrorRecord $_
        if ($info.status -eq 429) {
          $obj = $info.obj
          $hitCode = [string]$obj.code
          $hit429 = $true
          break
        }
      }
    }

    if (-not $hit429) {
      throw "did not hit 429 within $RateLimitProbeMaxRequests requests; consider lowering RATE_LIMIT_MAX_REQUESTS"
    }
    if ($hitCode -ne 'RATE_LIMIT_EXCEEDED') {
      throw "expected RATE_LIMIT_EXCEEDED code, got $hitCode"
    }
    Write-Host "  rate limit ok"
  }

  Write-Host "[6/6] PASS: P1-5 API governance works"
}
finally {
  try {
    $cleanupSql = @"
DELETE FROM disaster_data WHERE disaster_id IN ('p15_cls_${tag}_1','p15_cls_${tag}_2','p15_cls_${tag}_3');
DELETE FROM alarm_rules WHERE rule_code = '$ruleCode';
"@
    Invoke-MySql -Sql $cleanupSql | Out-Null
  } catch { }
}
