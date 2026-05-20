Param()

$ErrorActionPreference = "Stop"

docker compose --env-file .env down
Write-Host "容器已停止。"
