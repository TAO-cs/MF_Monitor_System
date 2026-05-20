Param(
  [string]$OutputRoot = ".\artifacts\jetson-sites"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $OutputRoot)) {
  throw "output root missing: $OutputRoot"
}

Get-ChildItem $OutputRoot -Directory | ForEach-Object {
  $zipPath = Join-Path $OutputRoot ($_.Name + ".zip")
  if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
  }
  Compress-Archive -Path $_.FullName -DestinationPath $zipPath -Force
}
