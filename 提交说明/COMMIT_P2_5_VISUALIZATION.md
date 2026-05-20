# COMMIT_P2_5_VISUALIZATION.md

## 变更目标
完成 P2-5「可视化平台」第一版工程落地：提供统一可视化入口页面、态势汇总接口、趋势分析接口、CSV 报表导出接口，并在 HA 网关中开放 `/dashboard` 页面访问能力。

## 新增内容
- `backend/app/visualization_api.py`
  - 新增可视化平台独立路由模块
  - 提供 `/dashboard` 页面与三类可视化数据接口
- `backend/app/dashboard_page.html`
  - 新增可视化平台前端单页
  - 包含地图定位、实时态势卡片、告警看板、趋势图与报表导出按钮
- `test/verify_p2_5_visualization.ps1`
  - 一键验收 P2-5 全流程
  - 覆盖页面可达、网关鉴权、MQTT 数据写入、态势接口、趋势接口、报表导出

## 主要改动
- `backend/app/main.py`
  - 接入 `visualization_api` 路由
- `nginx/conf.d/default.conf`
  - 单机网关新增 `/dashboard` 反向代理
- `nginx/ha/default_ha.conf`
  - HA 网关新增 `/dashboard` 反向代理
  - 修复 Nginx 配置文件编码，避免 BOM 导致容器启动失败
- `生产级平台.md`
  - 勾选 P2-5 完成状态
- `项目目录说明.md`
  - 补充可视化平台相关文件说明

## 新增接口
- `GET /dashboard`
- `GET /api/dashboard/summary`
- `GET /api/dashboard/trends`
- `GET /api/dashboard/report.csv`

## 验收命令
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start_p2_3_mysql_ha.ps1 -Env dev
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_p2_5_visualization.ps1 -EnvFile .env.dev.ha.mqtt.dbha
```

## 验收结果
- `/dashboard` 页面通过 HTTPS 网关访问成功
- `/api/dashboard/summary` 鉴权与数据返回正常
- MQTT 写入后地图点位、设备态势、告警数量联动更新
- `/api/dashboard/trends` 返回有效趋势桶数据
- `/api/dashboard/report.csv` 可导出并包含测试设备数据
- HA 环境验收通过：`PASS: P2-5 visualization baseline works`

## 回滚
如需回退到不含 P2-5 能力的运行状态，可回滚以下文件：
- `backend/app/main.py`
- `backend/app/visualization_api.py`
- `backend/app/dashboard_page.html`
- `nginx/conf.d/default.conf`
- `nginx/ha/default_ha.conf`
- `test/verify_p2_5_visualization.ps1`

回滚后重新执行 HA 栈启动脚本，并重启 `mf_nginx` 使网关配置生效。
