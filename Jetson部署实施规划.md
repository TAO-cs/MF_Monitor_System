# Jetson 部署实施规划

## 目标

本版本的 Jetson 侧目标不是先接真实摄像头，而是先把“可批量复制、可按站点独立部署”的交付链路跑通：

1. 使用统一 inventory 管理 10 台设备
2. 用模板渲染每台 Jetson 的 `device.ini`
3. 生成每站独立的站点包
4. 按站点安装 `rtsp_probe@SITE_CODE.service`
5. 用模拟器代替真实摄像头做周内联调

---

## 当前落地顺序

### 第 1 步：平台先启动

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_p2_3_mysql_ha.ps1 -Env dev
```

### 第 2 步：安全与环境检查

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check_env.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_week1_platform_security.ps1
```

### 第 3 步：导入 10 台设备

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap_devices_from_inventory.ps1 `
  -InventoryFile .\deploy\inventory\devices.csv `
  -BaseUrl https://127.0.0.1 `
  -ApiKey <API_KEY> `
  -SkipExisting `
  -AllowInsecureTls
```

### 第 4 步：渲染 Jetson 站点包

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\render_jetson_site_bundle.ps1 `
  -InventoryFile .\deploy\inventory\devices.csv `
  -TemplateFile .\jetson_edge_disnet_cpp\configs\templates\device.ini.template `
  -OutputRoot .\artifacts\jetson-sites `
  -EvidenceUploadApiKey <EVIDENCE_UPLOAD_API_KEY>

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package_jetson_bundles.ps1 -OutputRoot .\artifacts\jetson-sites
```

### 第 5 步：安装一个站点

```bash
export APP_SOURCE_ROOT=/home/nvidia/mudflow_project/jetson_edge_disnet_cpp
sudo bash /path/to/SITE01/deploy/install_site.sh SITE01 /path/to/SITE01
sudo systemctl enable rtsp_probe@SITE01.service
sudo systemctl start rtsp_probe@SITE01.service
```

### 第 6 步：启动 10 设备模拟演练

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_simulator_fleet.ps1 `
  -InventoryFile .\deploy\inventory\devices.csv `
  -MqttHost 127.0.0.1 `
  -Port 1883 `
  -Interval 5
```

---

## 关键文件

- `deploy/inventory/devices.csv`
- `scripts/bootstrap_devices_from_inventory.ps1`
- `jetson_edge_disnet_cpp/configs/templates/device.ini.template`
- `scripts/render_jetson_site_bundle.ps1`
- `scripts/package_jetson_bundles.ps1`
- `jetson_edge_disnet_cpp/deploy/install_site.sh`
- `jetson_edge_disnet_cpp/deploy/rtsp_probe@.service`
- `scripts/run_simulator_fleet.ps1`

---

## 站点包内容

每个站点包至少包含：

- `config/device.ini`
- `deploy/install_site.sh`
- `deploy/rtsp_probe@.service`

站点差异全部来自 `devices.csv`：

- `site_code`
- `aibox_id`
- `cam_id`
- `video_source`
- `mqtt_host`
- `mqtt_port`
- `evidence_upload_url`
- `latitude`
- `longitude`

---

## 本周验收目标

- 平台能稳定导入 10 台设备
- 可批量产出 10 个 Jetson 站点包
- 单个站点可独立安装为 `rtsp_probe@SITE_CODE.service`
- 无真实摄像头情况下可用模拟器完成端到端演练
