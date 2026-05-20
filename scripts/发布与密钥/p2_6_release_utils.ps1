function Get-P26LocalDockerImages {
  $raw = & docker images --format "{{.Repository}}:{{.Tag}}"
  if ($LASTEXITCODE -ne 0) {
    throw 'docker images failed'
  }
  return @($raw)
}

function Resolve-P26BackendBaseImage {
  param([string]$Preferred = 'python:3.12-slim')

  if ($env:BACKEND_BASE_IMAGE) {
    return $env:BACKEND_BASE_IMAGE
  }

  $localImages = Get-P26LocalDockerImages
  if ($localImages -contains $Preferred) {
    return $Preferred
  }

  $fallbacks = @(
    'mf_monitor_system-backend_api_1:latest',
    'mf_monitor_system-backend_api_2:latest',
    'mf_monitor_system-backend_worker:latest'
  )

  foreach ($image in $fallbacks) {
    if ($localImages -contains $image) {
      Write-Warning "Base image $Preferred unavailable locally, fallback to $image for offline compose build"
      return $image
    }
  }

  return $Preferred
}

function Resolve-P26RuntimeEnvFile {
  param(
    [string]$Env = 'dev',
    [string]$EnvFile = ''
  )

  if ($EnvFile) {
    if (-not (Test-Path $EnvFile)) {
      throw "Env file not found: $EnvFile"
    }
    return (Resolve-Path $EnvFile).Path
  }

  $candidates = @(
    ".env.$Env.ha.mqtt.dbha",
    ".env.$Env.ha.mqtt",
    ".env.$Env.ha",
    ".env.$Env",
    ".env"
  )

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      return (Resolve-Path $candidate).Path
    }
  }

  throw "No runtime env file found for env=$Env"
}

function Get-P26ComposeArgs {
  param(
    [Parameter(Mandatory = $true)][string]$RuntimeEnvFile
  )

  $args = @('--env-file', $RuntimeEnvFile, '-f', 'docker-compose.yml', '-f', 'docker-compose.p2-ha.yml')
  if ($RuntimeEnvFile -like '*.mqtt*' -and (Test-Path 'docker-compose.p2-mqtt.yml')) {
    $args += @('-f', 'docker-compose.p2-mqtt.yml')
  }
  if ($RuntimeEnvFile -like '*.dbha*' -and (Test-Path 'docker-compose.p2-mysql-ha.yml')) {
    $args += @('-f', 'docker-compose.p2-mysql-ha.yml')
  }
  return $args
}

function Get-P26EnvValue {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Key
  )

  $line = Get-Content $Path | Where-Object { $_ -match ('^' + [regex]::Escape($Key) + '=') } | Select-Object -First 1
  if (-not $line) { return '' }
  return ($line -replace ('^' + [regex]::Escape($Key) + '='), '')
}

function Set-P26EnvValues {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][hashtable]$Values
  )

  $lines = Get-Content $Path
  $remaining = @{}
  foreach ($entry in $Values.GetEnumerator()) {
    $remaining[$entry.Key] = [string]$entry.Value
  }

  $out = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    if ($line -match '^\s*#' -or $line -notmatch '=') {
      [void]$out.Add($line)
      continue
    }

    $parts = $line.Split('=', 2)
    $key = $parts[0].Trim()
    if ($remaining.ContainsKey($key)) {
      [void]$out.Add("$key=$($remaining[$key])")
      $remaining.Remove($key)
    } else {
      [void]$out.Add($line)
    }
  }

  foreach ($key in ($remaining.Keys | Sort-Object)) {
    [void]$out.Add("$key=$($remaining[$key])")
  }

  Set-Content -Path $Path -Value $out -Encoding UTF8
}

function Ensure-P26ReleaseDefaults {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Env = 'dev'
  )

  $stable = Get-P26EnvValue -Path $Path -Key 'RELEASE_VERSION_STABLE'
  $canary = Get-P26EnvValue -Path $Path -Key 'RELEASE_VERSION_CANARY'
  $worker = Get-P26EnvValue -Path $Path -Key 'RELEASE_VERSION_WORKER'
  $previous = Get-P26EnvValue -Path $Path -Key 'RELEASE_VERSION_PREVIOUS_STABLE'

  $defaults = @{}
  if (-not $stable) { $defaults['RELEASE_VERSION_STABLE'] = "$Env-stable" }
  if (-not $canary) { $defaults['RELEASE_VERSION_CANARY'] = "$Env-canary" }
  if (-not $worker) { $defaults['RELEASE_VERSION_WORKER'] = "$Env-worker" }
  if (-not $previous) { $defaults['RELEASE_VERSION_PREVIOUS_STABLE'] = '' }

  if ($defaults.Count -gt 0) {
    Set-P26EnvValues -Path $Path -Values $defaults
  }
}

function Invoke-P26ComposeUp {
  param(
    [Parameter(Mandatory = $true)][string]$RuntimeEnvFile,
    [Parameter(Mandatory = $true)][string[]]$Services,
    [switch]$Build
  )

  $env:HA_ENV_FILE = $RuntimeEnvFile
  $env:BACKEND_BASE_IMAGE = Resolve-P26BackendBaseImage
  $composeArgs = Get-P26ComposeArgs -RuntimeEnvFile $RuntimeEnvFile
  $args = @('compose') + $composeArgs + @('up', '-d')
  if ($Build) { $args += '--build' }
  $args += $Services

  & docker @args
  if ($LASTEXITCODE -ne 0) {
    throw "docker compose up failed for services: $([string]::Join(', ', $Services))"
  }

  if ($Services -contains 'nginx') {
    & docker restart mf_nginx | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw 'docker restart mf_nginx failed after compose up'
    }
    Start-Sleep -Seconds 2
  }
}
