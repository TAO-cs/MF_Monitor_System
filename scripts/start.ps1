Param()

$ErrorActionPreference = "Stop"

if (-not (Test-Path ".env")) {
  Copy-Item ".env.example" ".env"
}

docker compose --env-file .env up -d

Write-Host "MySQL + MQTT 已启动。"
Write-Host "下一步："
Write-Host "1) python -m venv .venv"
Write-Host "2) .\\.venv\\Scripts\\Activate.ps1"
Write-Host "3) pip install -r backend\\requirements.txt"
Write-Host "4) uvicorn app.main:app --reload --host 0.0.0.0 --port 8000  (在 backend 目录执行)"
