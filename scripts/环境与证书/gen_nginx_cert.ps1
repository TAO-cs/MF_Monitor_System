Param(
  [string]$CertDir = "nginx/certs",
  [string]$CommonName = "localhost",
  [int]$Days = 3650
)

$ErrorActionPreference = "Stop"

$certPath = Join-Path $CertDir "server.crt"
$keyPath = Join-Path $CertDir "server.key"

New-Item -ItemType Directory -Path $CertDir -Force | Out-Null

Write-Host "Generating self-signed cert for Nginx..."
docker run --rm -v "${PWD}/${CertDir}:/out" alpine/openssl req `
  -x509 -nodes -newkey rsa:2048 `
  -keyout /out/server.key `
  -out /out/server.crt `
  -days $Days `
  -subj "/CN=$CommonName"

if (-not (Test-Path $certPath) -or -not (Test-Path $keyPath)) {
  throw "Certificate generation failed: $certPath or $keyPath not found."
}

Write-Host "Certificate generated:"
Write-Host "  $certPath"
Write-Host "  $keyPath"
