# Jetson 部署实施规划

## 当前状态

当前 Jetson 端已经完成以下能力：

- [x] RTSP 拉流
- [x] 8 帧滑窗缓存
- [x] 预处理
- [x] TensorRT engine 推理
- [x] softmax 概率计算
- [x] `flood / mudslide` 类别映射
- [x] 稳定判定
- [x] 基础冷却去重
- [x] MQTT 上报 `device_status`
- [x] MQTT 上报 `classification`
- [x] HA 平台 MQTT 消费验证
- [x] MySQL 入库验证

当前版本定义：

**Jetson 单点位可联调版本**

---

## 总目标

把当前程序推进成适合正式部署的单点位边缘节点程序。

最终部署形态：

- 每个点位 1 台摄像头
- 每个点位 1 台 Jetson
- 每台 Jetson 运行 1 个标准服务进程
- 通过 MQTT 向平台 HA 环境上报

---

## 阶段 1：配置文件化

- [x] 新建 `jetson_edge_disnet_cpp/configs/device.ini`
- [x] 定义配置项：
  - `aibox_id`
  - `cam_id`
  - `rtsp_url`
  - `engine_path`
  - `mqtt_host`
  - `mqtt_port`
  - `confidence_threshold`
  - `stable_window`
  - `cooldown_sec`
  - `status_interval_sec`
- [x] 新建配置读取模块
- [x] `main.cpp` 改为优先读取配置文件
- [x] 命令行参数改为覆盖配置文件默认值
- [x] 配置文件方式编译通过
- [x] 配置文件方式运行验证通过

完成标准：

- 不修改代码，只修改配置文件，就能切换设备、平台和部署环境

---

## 阶段 2：事件截图与 image_path

- [x] 新建截图目录 `runtime/snapshots/`
- [x] 稳定事件触发时保存当前帧
- [ ] 截图文件名包含时间戳、设备编号、摄像头编号
- [ ] MQTT `classification` payload 中写入真实 `image_path`
- [ ] 平台数据库验证 `image_path` 不再为 `null`

完成标准：

- 平台数据库中的分类记录包含真实截图路径

---

## 阶段 3：重连与容错

- [ ] 增加 RTSP 断流检测
- [ ] 增加 RTSP 自动重连
- [ ] 增加 MQTT 断连后自动重连
- [ ] 增加初始化失败时的清晰错误信息
- [ ] 增加推理失败后的恢复策略
- [ ] 断流恢复测试通过
- [ ] MQTT 重连测试通过

完成标准：

- 断流或短时网络抖动后，程序可以自行恢复运行

---

## 阶段 4：日志体系

- [ ] 设计日志分级：`INFO / WARN / ERROR`
- [ ] 新建日志目录 `runtime/logs/`
- [ ] 启动日志落盘
- [ ] 配置加载日志落盘
- [ ] RTSP 连接日志落盘
- [ ] MQTT 连接日志落盘
- [ ] 推理结果日志落盘
- [ ] 事件上报日志落盘
- [ ] 异常恢复日志落盘

完成标准：

- 不看终端，也能通过日志文件排查问题

---

## 阶段 5：服务化部署

- [ ] 编写启动脚本
- [ ] 编写 `systemd service`
- [ ] 支持开机自启
- [ ] 支持崩溃自动重启
- [ ] 支持日志重定向
- [ ] `systemd` 部署测试通过

完成标准：

- Jetson 重启后程序自动拉起

---

## 阶段 6：本机重建 TensorRT engine

- [ ] 确认 ONNX 路径与输入输出约定
- [ ] 在当前 Jetson 本机重建 `.engine`
- [ ] 验证输入输出 shape 保持一致
- [ ] 使用新 engine 完成回归测试
- [ ] 替换旧 engine

完成标准：

- 使用本机生成的 engine 替代外部生成版本

---

## 阶段 7：最终部署验收

- [ ] 平台启动流程回归
- [ ] Jetson 启动流程回归
- [ ] RTSP 推流流程回归
- [ ] TensorRT 推理流程回归
- [ ] MQTT 上报流程回归
- [ ] MySQL 入库验证
- [ ] 平台页面展示验证
- [ ] 补充部署文档
- [ ] 补充排障文档

完成标准：

- 现场可按文档独立部署和复现

---

## 推荐实施顺序

- [ ] 阶段 1：配置文件化
- [ ] 阶段 2：事件截图与 `image_path`
- [ ] 阶段 3：重连与容错
- [ ] 阶段 4：日志体系
- [ ] 阶段 5：服务化部署
- [ ] 阶段 6：本机重建 engine
- [ ] 阶段 7：最终部署验收

---

## 当前下一步

- [x] 开始阶段 1：配置文件化
- [x] 新建 `jetson_edge_disnet_cpp/configs/device.ini`
