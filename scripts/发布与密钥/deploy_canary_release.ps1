Param(
  [ValidateSet('dev', 'test', 'prod')]
  [string]$Env = 'dev',
  [string]$EnvFile = '',
  [string]$CanaryVersion = '',
  [switch]$Build
)

$ErrorActionPreference = 'Stop'
. .\scripts\p2_6_release_utils.ps1

$runtimeEnv = Resolve-P26RuntimeEnvFile -Env $Env -EnvFile $EnvFile
Ensure-P26ReleaseDefaults -Path $runtimeEnv -Env $Env

if (-not $CanaryVersion) {
  $CanaryVersion = "$Env-canary-$(Get-Date -Format 'yyyyMMdd_HHmmss')"
}

$stableVersion = Get-P26EnvValue -Path $runtimeEnv -Key 'RELEASE_VERSION_STABLE'
$workerVersion = Get-P26EnvValue -Path $runtimeEnv -Key 'RELEASE_VERSION_WORKER'
if (-not $workerVersion) { $workerVersion = $stableVersion }

Set-P26EnvValues -Path $runtimeEnv -Values @{
  RELEASE_VERSION_CANARY = $CanaryVersion
  RELEASE_VERSION_WORKER = $workerVersion
}

Invoke-P26ComposeUp -RuntimeEnvFile $runtimeEnv -Services @('backend_api_2', 'nginx') -Build:$Build

Write-Host 'Canary release deployed.'
Write-Host "  runtime env : $runtimeEnv"
Write-Host "  stable      : $stableVersion"
Write-Host "  canary      : $CanaryVersion"
Write-Host '  route header: X-Release-Channel: canary'
