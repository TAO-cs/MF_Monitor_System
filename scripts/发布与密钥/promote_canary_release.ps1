Param(
  [ValidateSet('dev', 'test', 'prod')]
  [string]$Env = 'dev',
  [string]$EnvFile = '',
  [switch]$Build
)

$ErrorActionPreference = 'Stop'
. .\scripts\p2_6_release_utils.ps1

$runtimeEnv = Resolve-P26RuntimeEnvFile -Env $Env -EnvFile $EnvFile
Ensure-P26ReleaseDefaults -Path $runtimeEnv -Env $Env

$stableVersion = Get-P26EnvValue -Path $runtimeEnv -Key 'RELEASE_VERSION_STABLE'
$canaryVersion = Get-P26EnvValue -Path $runtimeEnv -Key 'RELEASE_VERSION_CANARY'
if (-not $canaryVersion) {
  throw 'RELEASE_VERSION_CANARY is empty, cannot promote canary release'
}

Set-P26EnvValues -Path $runtimeEnv -Values @{
  RELEASE_VERSION_PREVIOUS_STABLE = $stableVersion
  RELEASE_VERSION_STABLE = $canaryVersion
  RELEASE_VERSION_WORKER = $canaryVersion
}

Invoke-P26ComposeUp -RuntimeEnvFile $runtimeEnv -Services @('backend_api_1', 'backend_worker', 'nginx') -Build:$Build

Write-Host 'Canary release promoted to stable.'
Write-Host "  previous stable : $stableVersion"
Write-Host "  new stable      : $canaryVersion"
