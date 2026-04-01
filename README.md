# MF Monitor System - 雏形脚本

这个雏形实现了你当前阶段最关键的两条主线：
- MySQL 持久化存储
- MQTT 实时消息接入与消费入库

## 1. 你需要安装的软件

1. Docker Desktop (建议 4.x 以上)
2. Python 3.11+ (建议 3.11/3.12)
3. Git (可选)
4. MySQL 客户端工具 (可选，推荐 DBeaver 或 Navicat)
5. MQTT 客户端工具 (可选，推荐 MQTTX)

## 2. 目录结构

```text
MF_Monitor_System/
  backend/
    app/
      main.py
      config.py
      db.py
      models.py
      schemas.py
      mqtt_service.py
    requirements.txt
    simulator.py
  mqtt/
    mosquitto.conf
  scripts/
    start.ps1
    stop.ps1
    run_backend.ps1
    run_simulator.ps1
  sql/
    init.sql
  docker-compose.yml
  .env.example
```

## 3. 快速启动

### 3.1 启动 MySQL + MQTT

在项目根目录执行：

```powershell
Copy-Item .env.example .env
.\scripts\start.ps1
```

### 3.2 启动后端服务

```powershell
.\scripts\run_backend.ps1
```

### 3.3 启动模拟设备上报

新开一个终端：

```powershell
.\scripts\run_simulator.ps1 -Device DEV-001 -Interval 3
```

## 4. 可直接用的接口

1. 健康检查
```http
GET http://127.0.0.1:8000/health
```

2. 创建设备
```http
POST http://127.0.0.1:8000/devices
Content-Type: application/json

{
  "device_code": "DEV-002",
  "name": "演示设备2",
  "device_type": "rainfall_sensor",
  "location": "测试点B"
}
```

3. 设备列表
```http
GET http://127.0.0.1:8000/devices
```

4. 最近遥测数据
```http
GET http://127.0.0.1:8000/telemetry/latest?limit=20
```

5. 下发命令（MQTT）
```http
POST http://127.0.0.1:8000/commands/send
Content-Type: application/json

{
  "device_code": "DEV-001",
  "command_name": "reboot",
  "payload": {
    "delay": 5
  }
}
```

## 5. MQTT Topic 规范（当前雏形）

- 上报遥测: `mf/{device_id}/telemetry`
- 设备状态: `mf/{device_id}/status`
- 下发命令请求: `mf/{device_id}/command/req`
- 命令应答: `mf/{device_id}/command/resp`

## 6. 停止环境

```powershell
.\scripts\stop.ps1
```

## 7. 说明

- `sql/init.sql` 会在 MySQL 首次启动时自动建库建表。
- 后端在启动时会自动连接 MQTT 并订阅 `mf/+/telemetry` 和 `mf/+/status`。
- 收到消息后会将 metrics 拆分落库到 `telemetry_data`，并更新 `device_status`。
