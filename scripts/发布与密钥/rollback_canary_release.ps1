Param(
  [ValidateSet('dev', 'test', 'prod')]
  [string]$Env = 'dev',
  [string]$EnvFile = '',
  [string]$RollbackVersion = '',
  [switch]$Build
)

$ErrorActionPreference = 'Stop'
. .\scripts\p2_6_release_utils.ps1

$runtimeEnv = Resolve-P26RuntimeEnvFile -Env $Env -EnvFile $EnvFile
Ensure-P26ReleaseDefaults -Path $runtimeEnv -Env $Env

if (-not $RollbackVersion) {
  $RollbackVersion = Get-P26EnvValue -Path $runtimeEnv -Key 'RELEASE_VERSION_PREVIOUS_STABLE'
}
if (-not $RollbackVersion) {
  throw 'RollbackVersion missing and RELEASE_VERSION_PREVIOUS_STABLE is empty'
}

Set-P26EnvValues -Path $runtimeEnv -Values @{
  RELEASE_VERSION_STABLE = $RollbackVersion
  RELEASE_VERSION_CANARY = $RollbackVersion
  RELEASE_VERSION_WORKER = $RollbackVersion
}

Invoke-P26ComposeUp -RuntimeEnvFile $runtimeEnv -Services @('backend_api_1', 'backend_api_2', 'backend_worker', 'nginx') -Build:$Build

Write-Host 'Release rollback completed.'
Write-Host "  rollback version : $RollbackVersion"
