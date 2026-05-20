# Jetson 最终验收与交付清单

## 项目范围
- 部署形态：单点位 / 单摄像头 / 单 Jetson
- Jetson 服务：`jetson_edge_disnet_cpp`
- 平台环境：Windows HA 平台 + MQTT HA + MySQL HA
- 当前设备标识：`MF001 / CAM001`

## 当前版本状态
- [x] 配置文件驱动运行
- [x] RTSP 拉流与 8 帧滑窗推理
- [x] TensorRT 推理链路打通
- [x] 后处理稳定判定打通
- [x] MQTT 上报 `device_status`
- [x] MQTT 上报 `classification`
- [x] `image_path` 截图保存并入库
- [x] RTSP 断流自动重连
- [x] MQTT 断连自动重连
- [x] 日志落盘到 `runtime/logs`
- [x] `systemd` 服务化运行
- [x] 本机 Jetson 重建 TensorRT engine

## 最终验收清单

### 1. 环境验收
- [x] Windows HA 平台可以正常启动
- [x] MQTT HAProxy 入口 `192.168.31.185:1883` 可连通
- [x] Jetson 本机 `mediamtx` 可以正常运行
- [x] Windows `ffmpeg` 可以推流到 `rtsp://192.168.31.210:8554/mf001`
- [x] Jetson 服务可读取 `configs/device.ini`
- [x] Jetson 服务可读取本机生成的 `EdgeDisNet_fp16_jetson.engine`

### 2. 运行验收
- [x] `rtsp_probe.service` 状态为 `active (running)`
- [x] 服务启动后可自动打开 RTSP 流
- [x] 推理过程中 FPS 基本稳定在实时范围
- [x] 后处理可输出稳定类别结果
- [x] 稳定事件触发后可保存截图
- [x] 稳定事件触发后可发送 MQTT 分类消息
- [x] `device_status` 周期性上报成功
- [x] `classification` 周期性上报成功

### 3. 平台入库验收
- [x] `devices` 表存在 `MF001 / CAM001`
- [x] `device_status` 表中 `MF001 / CAM001` 状态为 `on`
- [x] `disaster_data` 表持续写入 `flood` 记录
- [x] `disaster_data.image_path` 不再为 `NULL`
- [x] 平台页面可看到设备在线

### 4. 异常恢复验收
- [x] 停止 Windows 推流后，Jetson 程序不会退出
- [x] 恢复推流后，Jetson 程序可自动恢复推理
- [x] 停止 MQTT 入口后，Jetson 程序不会退出
- [x] 恢复 MQTT 后，Jetson 程序可自动恢复上报
- [x] `systemd` 可在程序退出后自动拉起服务
- [ ] Jetson 重启后服务自动拉起验证
- [ ] 无推流状态下开机启动，待推流恢复后自动恢复业务验证

### 5. 日志与文件验收
- [x] `runtime/logs` 可生成运行日志文件
- [x] `runtime/snapshots` 可生成事件截图文件
- [x] 日志包含启动、MQTT、截图、分类事件
- [ ] 日志保留周期与清理策略确认
- [ ] 截图保留周期与清理策略确认

## 交付物清单

### 1. 代码与配置
- [x] `jetson_edge_disnet_cpp/src`
- [x] `jetson_edge_disnet_cpp/include`
- [x] `jetson_edge_disnet_cpp/CMakeLists.txt`
- [x] `jetson_edge_disnet_cpp/configs/device.ini`
- [x] `jetson_edge_disnet_cpp/scripts/run_rtsp_probe.sh`
- [x] `jetson_edge_disnet_cpp/deploy/rtsp_probe.service`

### 2. 模型与引擎
- [x] ONNX 模型：`/home/nvidia/mudflow_project/model_onnx/EdgeDisNet.onnx`
- [x] Jetson 本机 engine：`/home/nvidia/mudflow_project/model_onnx/EdgeDisNet_fp16_jetson.engine`
- [ ] 模型版本号记录
- [ ] engine 生成命令归档

### 3. 文档
- [x] `启动说明文件.txt`
- [x] `Jetson部署实施规划.md`
- [x] `Jetson最终验收与交付清单.md`
- [ ] 现场部署记录表
- [ ] 点位编号与设备编号映射表

## 现场部署检查清单
- [ ] Jetson 主机名确认
- [ ] Jetson 固定 IP 确认
- [ ] 摄像头 RTSP 地址确认
- [ ] `aibox_id / cam_id` 唯一性确认
- [ ] MQTT 平台地址确认
- [ ] `device.ini` 参数核对
- [ ] `rtsp_probe.service` 已启用开机自启
- [ ] 推理、截图、上报、入库全链路复测一次

## 回滚清单
- [ ] 保留 `device.ini.bak`
- [ ] 保留旧版 engine 文件
- [ ] 保留旧版服务文件
- [ ] 明确回滚命令

### 建议回滚命令
```bash
cp /home/nvidia/mudflow_project/jetson_edge_disnet_cpp/configs/device.ini.bak /home/nvidia/mudflow_project/jetson_edge_disnet_cpp/configs/device.ini
sudo systemctl restart rtsp_probe.service
```

## 交付结论
- 当前版本结论：**可试部署、可长期运行、已完成平台 HA 闭环联调**
- 正式批量部署前建议补齐：
  - [ ] Jetson 重启自启验证
  - [ ] 日志/截图清理策略
  - [ ] 现场部署记录表
  - [ ] 模型版本与 engine 生成命令归档

## 签字区
- 验收日期：
- 点位编号：
- Jetson 编号：
- 摄像头编号：
- 验收人：
- 备注：
