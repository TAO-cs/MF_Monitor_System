# MF Monitor System 可交付基线文档

## 1. 目标与范围
本基线版本用于验证“山洪泥石流监测端边云协同”方案中的最小可用闭环：
- MQTT 三类主题接入（classification / speed / device_status）
- MySQL 四张业务表落库
- REST API 按时间范围/设备查询
- API_KEY 鉴权
- 数据校验与脏数据拦截
- 索引优化与验证

## 2. 当前实现架构
- 数据库：本地 MySQL（数据库 `mf_monitor`）
- 消息中间件：Docker 中的 Mosquitto（容器 `mf_mqtt`）
- 后端：FastAPI + SQLAlchemy + paho-mqtt
- 测试脚本：`test/` 目录
- 运维脚本：`scripts/` 目录

## 3. 业务表（方案口径）
- `disaster_data`
- `speed_data`
- `device_location`
- `device_status`

## 4. MQTT 主题（方案口径）
- `disaster_monitoring/{aibox_id}/classification`
- `disaster_monitoring/{aibox_id}/speed`
- `disaster_monitoring/{aibox_id}/device_status`

## 5. API 接口
- `GET /health`（免鉴权）
- `GET /api/classification`
- `GET /api/speed`
- `GET /api/device_status`
- `GET /api/device_location`

## 6. 鉴权方式
- Header：`Authorization: Bearer <API_KEY>`
- 适用：所有 `/api/*`
- 免鉴权：`/health`
- API_KEY 来源：项目根目录 `.env` 中 `API_KEY=`

## 7. 入参校验规则（已落地）
- `disaster_type`：仅允许 `flood` 或 `mudslide`
- `confidence`：范围 `0.0 ~ 1.0`
- `speed`：必须数组、长度>=1、元素非负
- `online_status`：仅允许 `on` 或 `off`
- `aibox_id/cam_id`：长度限制
- 时间范围：`start_time <= end_time`

## 8. 时区策略
- 统一北京时间（Asia/Shanghai, UTC+8）
- 模拟器发送时间为北京时间
- 后端解析后按北京时间入库
- 查询脚本按北京时间生成时间窗口

## 9. 索引策略（复核后）
`disaster_data`
- `idx_disaster_time (timestamp)`
- `idx_disaster_device_time (aibox_id, cam_id, timestamp)`
- `idx_disaster_aibox_time (aibox_id, timestamp)`
- `idx_disaster_id (disaster_id)`

`speed_data`
- `idx_speed_time (timestamp)`
- `idx_speed_device_time (aibox_id, cam_id, timestamp)`
- `idx_speed_aibox_time (aibox_id, timestamp)`

## 10. 日常启动流程（标准）
1. 激活环境
```powershell
.\venv_MFSystem\Scripts\Activate.ps1
```
2. 启动 MQTT
```powershell
docker compose --env-file .env up -d mqtt
```
3. 启动后端
```powershell
.\scripts\run_backend.ps1
```
4. 启动模拟器（开两个终端并发）
```powershell
.\scripts\run_simulator.ps1 -Device MF001 -Cam CAM001 -Interval 3
.\scripts\run_simulator.ps1 -Device MF002 -Cam CAM002 -Interval 3
```

## 11. 一键验证指令
### 11.1 分类接口验证
```powershell
.\test\verify_classification_range.ps1 -MinutesBack 10
.\test\verify_classification_range.ps1 -MinutesBack 10 -AiboxId MF002 -CamId CAM002
```

### 11.2 速度接口验证
```powershell
.\test\verify_speed_range.ps1 -MinutesBack 10
.\test\verify_speed_range.ps1 -MinutesBack 10 -AiboxId MF002 -CamId CAM002
```

### 11.3 设备状态验证
```powershell
.\test\verify_device_status.ps1
.\test\verify_device_status.ps1 -AiboxId MF002 -CamId CAM002
```

### 11.4 speed_data 直连数据库增长验证
```powershell
.\test\verify_speed_db.ps1
```

### 11.5 三表增长监控
```powershell
.\test\watch_data_growth.ps1
```

### 11.6 脏数据测试
```powershell
.\test\test_dirty_data.ps1
```

## 12. 鉴权验证指令
1. 不带 Header（应 401）
```powershell
Invoke-RestMethod "http://127.0.0.1:8000/api/device_status"
```
2. 带错 key（应 401）
```powershell
Invoke-RestMethod "http://127.0.0.1:8000/api/device_status" -Headers @{Authorization="Bearer wrong-key"}
```
3. 带对 key（应成功）
```powershell
$k = (Get-Content .env | Select-String "^API_KEY=").ToString().Split("=")[1]
Invoke-RestMethod "http://127.0.0.1:8000/api/device_status" -Headers @{Authorization="Bearer $k"}
```

## 13. API_KEY 安全操作
- 轮换 API_KEY（随机生成并写回 `.env`）
```powershell
.\scripts\rotate_api_key.ps1
```
- 轮换后必须重启后端
```powershell
.\scripts\run_backend.ps1
```

## 14. 索引复核执行
- 应用索引优化（可重复执行）
```powershell
.\scripts\apply_index_review.ps1
```
- 验证索引
```sql
SHOW INDEX FROM disaster_data;
SHOW INDEX FROM speed_data;
```

## 15. 故障排查速查
- `401 Missing Authorization header`：未带鉴权头
- `401 Invalid API key`：key 不匹配（注意 Base64 尾部 `=`）
- `API 时间解析错误`：检查 `+08:00` 是否 URL 编码
- `MQTT 容器重启`：检查 `mqtt/mosquitto.conf` 编码与容器日志
- `Access denied`：检查 `.env` 账号密码与 MySQL 授权
