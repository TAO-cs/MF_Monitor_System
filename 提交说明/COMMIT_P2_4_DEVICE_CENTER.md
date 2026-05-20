# COMMIT_P2_4_DEVICE_CENTER.md

## 变更目标
完成 P2-4「设备管理中心」第一版工程落地：设备注册、设备分组、状态总览、配置下发、权限控制、命令记录与验收脚本。

## 新增内容
- `backend/app/device_api.py`
  - 新增设备管理中心独立路由模块
  - 提供设备、分组、总览、配置下发、命令查询 API
- `backend/app/device_center.py`
  - 启动时自动把历史数据中的设备补登记到 `devices`
  - MQTT 入库时自动确保设备记录存在
- `test/verify_p2_4_device_center.ps1`
  - 一键验收 P2-4 全流程
  - 覆盖创建设备、创建设备组、分组绑定、状态写入、总览查询、配置下发、权限拒绝

## 主要改动
- `backend/app/models.py`
  - 新增 `Device`
  - 新增 `DeviceGroup`
  - 新增 `DeviceGroupMember`
  - 新增 `DeviceCommand`
- `backend/app/schemas.py`
  - 新增设备管理相关请求模型
- `backend/app/main.py`
  - 接入 `device_api` 路由
  - 启动时执行设备注册补齐
- `backend/app/mqtt_service.py`
  - 新增管理消息发布能力
  - MQTT 数据接入时自动补登记设备
- `sql/init.sql`
  - 新增设备中心相关表结构
- `scripts/start_p2_1_backend_ha.ps1`
  - 启动时增加 `--build`，确保 HA 容器使用最新代码
- `scripts/start_p2_3_mysql_ha.ps1`
  - 启动时增加 `--build`，确保 HA 容器使用最新代码

## 新增接口
- `GET /api/devices`
- `POST /api/devices`
- `PUT /api/devices/{device_id}`
- `PATCH /api/devices/{device_id}/enabled`
- `PATCH /api/devices/{device_id}/permissions`
- `GET /api/device_groups`
- `POST /api/device_groups`
- `PUT /api/device_groups/{group_id}`
- `POST /api/device_groups/{group_id}/members/{device_id}`
- `DELETE /api/device_groups/{group_id}/members/{device_id}`
- `GET /api/device_overview`
- `GET /api/device_commands`
- `POST /api/devices/{device_id}/config`

## 验收命令
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start_p2_3_mysql_ha.ps1 -Env dev
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_p2_4_device_center.ps1 -EnvFile .env.dev.ha.mqtt.dbha
```

## 验收结果
- 设备组创建通过
- 设备注册通过
- 分组绑定通过
- MQTT 在线状态写入通过
- 设备总览查询通过
- 配置下发成功并写入 `device_commands`
- 禁用配置权限后返回 `403`，控制生效

## 回滚
如需回退到不含 P2-4 能力的运行状态，可回滚以下文件：
- `backend/app/main.py`
- `backend/app/models.py`
- `backend/app/schemas.py`
- `backend/app/mqtt_service.py`
- `backend/app/device_api.py`
- `backend/app/device_center.py`
- `sql/init.sql`

并重新执行 HA 栈启动脚本完成镜像重建。
