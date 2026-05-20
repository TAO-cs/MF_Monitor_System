# Jetson 最终验收与交付清单

## 一、交付目标

本周交付的不是“真实摄像头正式运行版”，而是：

- 平台可用
- 10 台设备台账可导入
- Jetson 配置可按站点生成
- 单站可独立安装
- 无摄像头条件下可做 10 设备联调

---

## 二、必须先走的顺序

1. 启动 HA 平台
2. 跑环境与安全检查
3. 从 inventory 导入设备
4. 生成 Jetson 站点包
5. 安装一个站点
6. 启动 10 设备模拟联调
7. 记录验收结果

---

## 三、必跑命令

### 1. 平台启动

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_p2_3_mysql_ha.ps1 -Env dev
```

### 2. 周计划验证

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_platform_security.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_inventory_bootstrap.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_jetson_bundle.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_site_bundle_packaging.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_fleet_rehearsal.ps1
```

### 3. 平台设备导入

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap_devices_from_inventory.ps1 -InventoryFile .\deploy\inventory\devices.csv -BaseUrl https://127.0.0.1 -ApiKey <API_KEY> -SkipExisting -AllowInsecureTls
```

### 4. Jetson 出包

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\render_jetson_site_bundle.ps1 -InventoryFile .\deploy\inventory\devices.csv -TemplateFile .\jetson_edge_disnet_cpp\configs\templates\device.ini.template -OutputRoot .\artifacts\jetson-sites -EvidenceUploadApiKey <EVIDENCE_UPLOAD_API_KEY>
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package_jetson_bundles.ps1 -OutputRoot .\artifacts\jetson-sites
```

### 5. 模拟联调

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_simulator_fleet.ps1 -InventoryFile .\deploy\inventory\devices.csv -MqttHost 127.0.0.1 -Port 1883 -Interval 5
```

### 6. 平台与可视化验收

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_p2_3_mysql_ha.ps1 -EnvFile .env.dev.ha.mqtt.dbha
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_p2_5_visualization.ps1 -EnvFile .env.dev.ha.mqtt.dbha -ApiBase http://127.0.0.1:18001 -GatewayBase http://127.0.0.1:18001
```

---

## 四、交付物清单

- `deploy/inventory/devices.csv`
- `scripts/bootstrap_devices_from_inventory.ps1`
- `scripts/render_jetson_site_bundle.ps1`
- `scripts/package_jetson_bundles.ps1`
- `scripts/run_simulator_fleet.ps1`
- `jetson_edge_disnet_cpp/configs/templates/device.ini.template`
- `jetson_edge_disnet_cpp/deploy/install_site.sh`
- `jetson_edge_disnet_cpp/deploy/rtsp_probe@.service`
- `docs/landing/week1-go-live-runbook.md`

---

## 五、通过标准

- 10 台设备可从 inventory 一次性导入
- 10 个站点包可渲染并压缩
- `SITE01` 到 `SITE10` 的 `device.ini` 均正确带出 `video_source`
- `rtsp_probe@SITE_CODE.service` 可按站点启用
- 模拟器联调后，平台能持续收到 `device_status`、`classification`、`speed`
- 平台 HA 和可视化验证通过

---

## 六、交付前留档

- 平台启动截图
- `docker ps` 结果截图
- 10 台设备导入结果截图
- `artifacts/jetson-sites` 目录截图
- `SITE01.zip` 解压后的配置截图
- `/api/device_overview`、`/api/dashboard/summary` 返回截图
- `systemctl status rtsp_probe@SITE01.service` 截图

---

## 七、风险说明

- 当前尚未接入真实摄像头，`video_source` 仍以本地视频或模拟 RTSP 为主
- 当前周内版本重点是“可交付、可批量部署、可演练”，不是完整 OTA 发布系统
- `artifacts/` 为本地生成目录，建议作为交付留档输出，不作为源码提交内容
