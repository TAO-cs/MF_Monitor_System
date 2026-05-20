# Jetson 远程更新设计方案

## 本周定位

本周先不实现完整 OTA，而是先把后续远程更新必须依赖的基础交付形态固定下来：

1. inventory 统一管理设备台账
2. 站点配置模板化
3. 每站生成独立部署包
4. Jetson 安装脚本标准化
5. systemd 服务改为 `rtsp_probe@SITE_CODE.service`

这意味着后续 OTA 可以直接围绕“站点包 + 通用应用目录”来做，而不需要重新设计部署边界。

---

## 当前推荐流程

### 1. 平台启动

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_p2_3_mysql_ha.ps1 -Env dev
```

### 2. 环境检查

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check_env.ps1
```

### 3. 设备导入

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap_devices_from_inventory.ps1 `
  -InventoryFile .\deploy\inventory\devices.csv `
  -BaseUrl https://127.0.0.1 `
  -ApiKey <API_KEY> `
  -SkipExisting `
  -AllowInsecureTls
```

### 4. 生成站点包

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\render_jetson_site_bundle.ps1 `
  -InventoryFile .\deploy\inventory\devices.csv `
  -TemplateFile .\jetson_edge_disnet_cpp\configs\templates\device.ini.template `
  -OutputRoot .\artifacts\jetson-sites `
  -EvidenceUploadApiKey <EVIDENCE_UPLOAD_API_KEY>

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package_jetson_bundles.ps1 -OutputRoot .\artifacts\jetson-sites
```

### 5. 单站安装

```bash
export APP_SOURCE_ROOT=/home/nvidia/mudflow_project/jetson_edge_disnet_cpp
sudo bash /path/to/SITE01/deploy/install_site.sh SITE01 /path/to/SITE01
sudo systemctl enable rtsp_probe@SITE01.service
sudo systemctl start rtsp_probe@SITE01.service
```

### 6. 模拟联调

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_simulator_fleet.ps1 `
  -InventoryFile .\deploy\inventory\devices.csv `
  -MqttHost 127.0.0.1 `
  -Port 1883 `
  -Interval 5
```

---

## 后续 OTA 设计边界

后续真正做远程更新时，建议拆成两层：

### 层 1：通用应用包

内容：

- `jetson_edge_disnet_cpp`
- 依赖说明
- 服务模板

特点：

- 所有 Jetson 共用
- 版本统一
- 适合做滚动升级

### 层 2：站点配置包

内容：

- `config/device.ini`
- 站点级 `site_code / aibox_id / cam_id / video_source`

特点：

- 每站独立
- 由 inventory 渲染
- 与设备身份强绑定

---

## 为什么先这样做

这样拆分后，后续 OTA 的复杂度会明显下降：

- 不需要为每台 Jetson 单独维护代码分支
- 真实摄像头到货前，`video_source` 可以继续用本地视频文件或 RTSP 模拟源
- 一台设备失败不会影响其他站点包
- 10 台 Jetson 可以并行部署、并行回滚

---

## 本周先验收这些

- `devices.csv` 作为唯一设备台账来源
- `device.ini.template` 支持 `video_source`
- `render_jetson_site_bundle.ps1` 能生成 10 站点配置
- `install_site.sh` 能将单站部署到 `/opt/mf-monitor/<SITE_CODE>`
- `run_simulator_fleet.ps1` 能用于无摄像头演练
