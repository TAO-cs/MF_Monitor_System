# P2-1 后端高可用（基线）

## 目标
- 双 API 实例负载均衡
- 网关故障自动摘除（被动健康检查）
- 服务无状态化（API 实例不消费 MQTT）
- 单独 ingestion worker 负责 MQTT 消费与通知任务

## 关键文件
- `backend/app/config.py`
- `backend/app/main.py`
- `backend/app/mqtt_service.py`
- `backend/Dockerfile`
- `docker-compose.p2-ha.yml`
- `nginx/conf.d/default_ha.conf`
- `scripts/start_p2_1_backend_ha.ps1`
- `scripts/stop_p2_1_backend_ha.ps1`
- `test/verify_p2_1_backend_ha.ps1`

## 启动
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_p2_1_backend_ha.ps1 -Env dev
```

## 验收
```powershell
powershell -ExecutionPolicy Bypass -File .\test\verify_p2_1_backend_ha.ps1 -EnvFile .env.dev.ha
```

## 预期
- 直连健康检查：
  - `http://127.0.0.1:18001/health` -> `instance_id=backend-api-1`, `ingestion_enabled=false`
  - `http://127.0.0.1:18002/health` -> `instance_id=backend-api-2`, `ingestion_enabled=false`
  - `http://127.0.0.1:18003/health` -> `instance_id=backend-worker`, `ingestion_enabled=true`
- 网关 `https://127.0.0.1/health` 返回 200
- 停止 `mf_backend_api_1` 后，网关请求仍可返回 200（切到 api_2）
- API 实例 `mf_mqtt_connected=0`，worker `mf_mqtt_connected=1`

## 停止
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop_p2_1_backend_ha.ps1 -Env dev
```

## 说明
- 首次执行会构建 backend 镜像，需要 Docker 能访问镜像仓库。
- `start_p2_1_backend_ha.ps1` 会基于 `.env.dev` 生成 `.env.dev.ha`（容器内地址改为 `mysql`/`mqtt`）。
## 网络受限时的镜像拉取
如果 `python:3.12-slim` 拉取失败，可在 `.env.dev` 追加一行后重试：

```env
BACKEND_BASE_IMAGE=mcr.microsoft.com/devcontainers/python:1-3.12-bookworm
```

然后重新执行：
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_p2_1_backend_ha.ps1 -Env dev
```

脚本会生成运行时环境文件：`<你的Env文件>.ha`，例如 `.env.dev.ha`。