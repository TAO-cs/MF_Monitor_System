# Week-1 Go-Live Runbook

## 1. 适用范围

本 Runbook 面向本周落地版本，目标是：

- 不依赖真实摄像头，先完成平台、设备台账、Jetson 配置包、10 设备模拟联调
- 支持 10 台 Jetson 按站点独立部署
- 所有站点配置统一由 `deploy/inventory/devices.csv` 生成

---

## 2. Pre-flight

### 2.1 必备输入

- `.env.dev.ha.mqtt.dbha` 或当前实际使用的环境文件
- `PLATFORM_ADMIN_USERNAME`
- `PLATFORM_ADMIN_PASSWORD`
- `API_KEY`
- `EVIDENCE_UPLOAD_API_KEY`

### 2.2 先做检查

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check_env.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_platform_security.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_inventory_bootstrap.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_jetson_bundle.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_site_bundle_packaging.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_fleet_rehearsal.ps1
```

通过标准：

- 所有自定义周计划验证通过
- 环境变量缺失时会明确报错
- `devices.csv` 为 10 台设备

---

## 3. 平台启动

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_p2_3_mysql_ha.ps1 -Env dev
```

启动后确认：

- `http://127.0.0.1:18001/health`
- `https://127.0.0.1/console`
- `docker ps` 中 `backend_api_1`、`backend_api_2`、`backend_worker`、`mysql`、`mysql_replica`、`mqtt_primary`、`mqtt_secondary`、`nginx` 全部正常

平台 HA 验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_p2_3_mysql_ha.ps1 -EnvFile .env.dev.ha.mqtt.dbha
```

---

## 4. Inventory 导入设备

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap_devices_from_inventory.ps1 `
  -InventoryFile .\deploy\inventory\devices.csv `
  -BaseUrl https://127.0.0.1 `
  -ApiKey <API_KEY> `
  -SkipExisting `
  -AllowInsecureTls
```

验收点：

- `/api/devices` 可看到 10 台设备
- `/api/device_overview` 返回 `total = 10`
- 每台设备具备 `site_code`、`video_source`、`mqtt_host` 等结构化元数据

---

## 5. 生成 Jetson 站点包

### 5.1 Windows 侧渲染

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\render_jetson_site_bundle.ps1 `
  -InventoryFile .\deploy\inventory\devices.csv `
  -TemplateFile .\jetson_edge_disnet_cpp\configs\templates\device.ini.template `
  -OutputRoot .\artifacts\jetson-sites `
  -EvidenceUploadApiKey <EVIDENCE_UPLOAD_API_KEY>
```

### 5.2 打包

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package_jetson_bundles.ps1 -OutputRoot .\artifacts\jetson-sites
```

输出结果：

- `artifacts/jetson-sites/SITE01/config/device.ini`
- `artifacts/jetson-sites/SITE01/deploy/install_site.sh`
- `artifacts/jetson-sites/SITE01/deploy/rtsp_probe@.service`
- `artifacts/jetson-sites/SITE01.zip`
- 直到 `SITE10.zip`

---

## 6. Jetson 单站安装

前提：

- Jetson 已同步通用应用目录 `jetson_edge_disnet_cpp`
- 已将对应站点包解压，例如 `SITE01`

执行：

```bash
export APP_SOURCE_ROOT=/home/nvidia/mudflow_project/jetson_edge_disnet_cpp
sudo bash /path/to/SITE01/deploy/install_site.sh SITE01 /path/to/SITE01
sudo systemctl enable rtsp_probe@SITE01.service
sudo systemctl start rtsp_probe@SITE01.service
sudo systemctl status rtsp_probe@SITE01.service --no-pager
```

验收点：

- `/opt/mf-monitor/SITE01/config/device.ini` 已落地
- `rtsp_probe@SITE01.service` 启动成功
- `video_source`、`aibox_id`、`cam_id` 与 inventory 一致

---

## 7. 无摄像头 10 设备联调

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_simulator_fleet.ps1 `
  -InventoryFile .\deploy\inventory\devices.csv `
  -Host 127.0.0.1 `
  -Port 1883 `
  -Interval 5
```

联调观察点：

- `/api/device_overview` 返回 10 台设备
- `/api/dashboard/summary` 中设备数为 10
- `/api/classification` 持续增长
- `/api/speed` 持续增长

可视化验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_p2_5_visualization.ps1
```

---

## 8. 最终验收命令

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_platform_security.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_inventory_bootstrap.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_jetson_bundle.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_site_bundle_packaging.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_fleet_rehearsal.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_p2_3_mysql_ha.ps1 -EnvFile .env.dev.ha.mqtt.dbha
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_p2_5_visualization.ps1
```

通过标准：

- 周计划内新增验证全部通过
- 平台 HA 验证通过
- 可视化验证通过
- 站点包可重复渲染
- 设备导入脚本可重复执行

---

## 9. Cutover Checklist

- 已替换全部默认口令与默认 API Key
- `devices.csv` 已按真实站点信息维护
- `EVIDENCE_UPLOAD_API_KEY` 已替换为正式值
- Jetson 站点包已按站点归档保存
- 演练截图、接口返回、服务状态日志已留档
- 已确认回滚方式：停平台、停止模拟器、恢复上一版配置包
