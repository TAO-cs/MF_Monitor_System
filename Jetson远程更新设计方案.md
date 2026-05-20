# Jetson 远程更新设计方案

## 1. 文档定位
本文件用于定义本系统中 Jetson 边缘节点的远程更新方案，覆盖：

- 脚本更新
- 模型更新
- TensorRT engine 更新
- 配置更新
- 更新状态回传
- 回滚与容灾

本文件是**设计方案与实施细则**，用于后续研发与部署，不代表当前仓库已经全部实现。

---

## 2. 目标与边界

### 2.1 目标
- 支持实验室对野外 Jetson 设备进行远程版本迭代。
- 支持批量下发更新任务，并可按设备、分组、灰度批次控制。
- 支持脚本、模型、配置分离更新。
- 支持失败自动回滚。
- 支持更新过程全链路可观测、可审计。
- 支持弱网、断线重连、重复命令幂等。

### 2.2 非目标
- 不在 MQTT 中直接传输大模型文件。
- 不依赖人工 SSH 登录作为主更新方式。
- 不允许直接覆盖运行中版本而不保留回滚副本。
- 不将远程更新与实时视频链路耦合。

---

## 3. 当前系统基线
基于当前项目现状，Jetson 节点已具备以下基础能力：

- RTSP 拉流
- TensorRT 推理
- MQTT 上报 `device_status` / `classification`
- 截图保存与证据图上传
- `systemd` 常驻运行
- 本地配置文件驱动

因此远程更新方案应优先复用：

- 现有 MQTT 通道作为**控制面**
- 现有后端 / Nginx / HA 作为**管理面**
- 新增 HTTPS 文件分发作为**数据面**

---

## 4. 总体方案

### 4.1 推荐总体架构
采用“三层架构”：

1. 控制面：`MQTT over TLS`
2. 文件分发：`HTTPS`
3. 人工运维：`WireGuard + SSH`

### 4.2 设计原则
- 小消息走 MQTT
- 大文件走 HTTPS
- 人工排障走私网 SSH
- 更新动作由 Jetson 本地代理执行，不由平台强行推文件覆盖

### 4.3 推荐协议分工

| 功能 | 协议 | 说明 |
|---|---|---|
| 心跳/状态上报 | MQTT TLS | 小消息、长连接 |
| 更新命令下发 | MQTT TLS | 平台发版本和 manifest 地址 |
| 包下载 | HTTPS | 脚本包、模型包、engine、配置包 |
| 更新结果回传 | MQTT TLS | 状态、进度、失败原因 |
| 人工远程维护 | WireGuard + SSH | 不暴露公网 SSH |

---

## 5. 技术方案总览

### 5.1 Jetson 端新增组件
新增一个独立服务：

`update_agent`

职责：
- 订阅更新命令
- 拉取 manifest
- 下载更新文件
- 校验哈希
- 解压/落盘/切换版本
- 调用 `systemctl restart`
- 健康检查
- 成功确认或失败回滚
- 上报更新状态

### 5.2 平台侧新增能力
平台侧新增以下能力：

- 更新任务管理
- 设备分组发布
- 更新包索引
- manifest 生成与版本登记
- 更新状态展示
- 审计日志

### 5.3 文件仓库
实验室侧部署 HTTPS 文件源，可选：

- Nginx 静态文件服务
- MinIO / S3 对象存储
- 自建制品仓库

建议所有更新文件都带：

- 版本号
- SHA256
- 发布时间
- 适配设备范围
- 回滚版本指针

---

## 6. Jetson 端目录设计

建议在 Jetson 上统一为：

```text
/opt/mf-node/
  current -> /opt/mf-node/releases/2026.05.07-1/
  releases/
    2026.05.07-1/
      bin/
      configs/
      models/
      manifest.json
  downloads/
  backups/
  runtime/
    logs/
    snapshots/
  state/
    update_state.json
    last_good_version
```

说明：
- `current` 软链接指向当前启用版本
- `releases/` 保存历史版本
- `downloads/` 保存下载中的临时文件
- `backups/` 保存配置或关键文件回滚副本
- `state/` 保存更新状态机信息

---

## 7. 版本对象与更新粒度

### 7.1 建议分成四类对象
1. 脚本包
2. 模型文件
3. TensorRT engine
4. 配置文件

### 7.2 更新粒度建议

#### 方案 A：全量发布
一次更新包含：
- 可执行文件
- 配置
- 模型
- engine

优点：
- 一致性高
- 版本最清晰

缺点：
- 包较大
- 下载时间更长

#### 方案 B：分对象发布
分别更新：
- `app`
- `config`
- `model`
- `engine`

优点：
- 灵活
- 节省流量

缺点：
- 需要兼容性管理

### 7.3 推荐
采用“**统一 manifest + 分对象文件**”的方式：
- 命令层面以一个版本为单位
- 实际可只替换其中几个对象

---

## 8. Manifest 设计

### 8.1 示例
```json
{
  "version": "2026.05.07-1",
  "release_channel": "stable",
  "created_at": "2026-05-07T14:30:00+08:00",
  "min_agent_version": "1.0.0",
  "compatible_device_types": ["jetson-orin-nx"],
  "artifacts": {
    "app_package": {
      "url": "https://updates.example.com/releases/2026.05.07-1/app.tar.gz",
      "sha256": "sha256-app",
      "size_bytes": 12345678
    },
    "engine": {
      "url": "https://updates.example.com/releases/2026.05.07-1/EdgeDisNet_fp16_jetson.engine",
      "sha256": "sha256-engine",
      "size_bytes": 23456789
    },
    "config": {
      "url": "https://updates.example.com/releases/2026.05.07-1/device.ini",
      "sha256": "sha256-config",
      "size_bytes": 2048
    }
  },
  "post_actions": {
    "restart_services": ["rtsp_probe.service"],
    "health_check_timeout_sec": 120
  },
  "rollback": {
    "fallback_version": "2026.05.04-3"
  }
}
```

### 8.2 必须字段
- `version`
- `created_at`
- `artifacts`
- 每个 artifact 的 `url` / `sha256`

### 8.3 建议字段
- `release_channel`
- `min_agent_version`
- `compatible_device_types`
- `rollback.fallback_version`

---

## 9. MQTT 主题设计

### 9.1 建议主题

#### 平台 -> Jetson
```text
disaster_monitoring/{aibox_id}/update/command
```

#### Jetson -> 平台
```text
disaster_monitoring/{aibox_id}/update/status
disaster_monitoring/{aibox_id}/update/progress
```

### 9.2 命令消息示例
```json
{
  "command_id": "upd_20260507_0001",
  "command": "update",
  "target_version": "2026.05.07-1",
  "manifest_url": "https://updates.example.com/releases/2026.05.07-1/manifest.json",
  "force": false,
  "channel": "stable"
}
```

### 9.3 状态消息示例
```json
{
  "command_id": "upd_20260507_0001",
  "aibox_id": "MF001",
  "status": "downloading",
  "progress": 42,
  "current_version": "2026.05.04-3",
  "target_version": "2026.05.07-1",
  "timestamp": "2026-05-07T14:35:00+08:00"
}
```

### 9.4 终态消息示例
```json
{
  "command_id": "upd_20260507_0001",
  "aibox_id": "MF001",
  "status": "success",
  "current_version": "2026.05.07-1",
  "previous_version": "2026.05.04-3",
  "timestamp": "2026-05-07T14:39:00+08:00"
}
```

失败示例：
```json
{
  "command_id": "upd_20260507_0001",
  "aibox_id": "MF001",
  "status": "failed",
  "stage": "hash_verify",
  "reason": "sha256 mismatch",
  "rolled_back": true,
  "current_version": "2026.05.04-3",
  "timestamp": "2026-05-07T14:37:00+08:00"
}
```

---

## 10. `update_agent` 状态机设计

### 10.1 状态流转
```text
idle
 -> manifest_fetching
 -> downloading
 -> verifying
 -> staging
 -> switching
 -> restarting
 -> health_checking
 -> success

任意阶段失败:
 -> failed
 -> rollbacking
 -> rolled_back / rollback_failed
```

### 10.2 幂等要求
- `command_id` 必须唯一
- 已执行成功的 `command_id` 不重复执行
- 正在执行中的重复命令直接返回当前状态

### 10.3 中断恢复
若 Jetson 更新过程中断电，`update_agent` 启动后应读取：

```text
/opt/mf-node/state/update_state.json
```

并判断：
- 是否继续未完成下载
- 是否回滚到 `last_good_version`

---

## 11. 更新实施流程

### 11.1 标准流程
1. 平台创建更新任务
2. 平台向目标 Jetson 发布 MQTT 更新命令
3. Jetson 拉取 manifest
4. 校验设备型号、agent 版本、通道是否合法
5. 下载更新对象到 `downloads/`
6. 校验 SHA256
7. 解压或拷贝到 `releases/<version>/`
8. 写入新的 manifest
9. 切换 `current` 软链接
10. 重启目标服务
11. 进行健康检查
12. 成功则写 `last_good_version`
13. 失败则回滚

### 11.2 健康检查项
建议至少检查：
- `systemctl is-active rtsp_probe.service`
- 日志中是否出现初始化成功关键字
- MQTT 心跳是否恢复
- 最近一次推理是否成功

---

## 12. 回滚设计

### 12.1 自动回滚触发条件
- 下载失败
- 哈希校验失败
- 解压失败
- 服务启动失败
- 健康检查超时

### 12.2 回滚策略
1. 切回 `current -> last_good_version`
2. 重启服务
3. 上报 `rolled_back`
4. 保留失败版本目录，供后续排查

### 12.3 不允许的做法
- 直接删除上一版本
- 不保留失败现场
- 先删旧版本再切换新版本

---

## 13. 安全设计

### 13.1 通信安全
- MQTT 必须使用 TLS
- HTTPS 必须使用 TLS
- API Key / Token 要支持轮换

### 13.2 文件安全
- 所有更新文件必须做 SHA256 校验
- 建议对 manifest 做签名校验
- 禁止执行未校验的下载文件

### 13.3 访问控制
- 平台侧只有管理员可创建更新任务
- Jetson 仅接受来自白名单 Broker 的命令
- `update_agent` 只允许固定安装路径

### 13.4 人工维护通道
建议使用：
- WireGuard 组网
- 隧道内 SSH

不建议：
- 公网直开 SSH 22
- 共享 root 密码

---

## 14. 可观测性设计

### 14.1 Jetson 本地日志
建议日志文件：
```text
/opt/mf-node/runtime/logs/update_agent.log
```

### 14.2 平台侧状态字段
建议记录：
- 当前版本
- 上次成功版本
- 更新状态
- 更新时间
- 最后失败原因
- 当前 release channel

### 14.3 审计要求
平台应记录：
- 谁发起更新
- 何时发起
- 哪些设备收到命令
- 哪些设备成功 / 失败 / 回滚

---

## 15. 技术手段选型建议

### 15.1 控制面
推荐：
- `MQTT v3.1.1 / v5`
- `QoS 1`
- 保留消息按场景决定

### 15.2 数据面
推荐：
- `HTTPS`
- 支持断点续传
- 支持对象存储 URL 或反向代理静态下载

### 15.3 Jetson 本地实现建议
可选实现语言：
- Python：开发快，适合 `update_agent`
- C++：若要与主程序统一可选，但开发成本高

推荐：
- `update_agent` 使用 Python 单独实现
- 推理主程序继续维持 C++ / systemd 服务

### 15.4 包格式建议
- 脚本与二进制：`tar.gz`
- 配置：`ini/yaml/json`
- 模型：`onnx`
- 部署 engine：`.engine`

---

## 16. 实施细则

### 16.1 第一阶段
目标：先实现最小远程更新闭环

范围：
- MQTT 命令下发
- HTTPS 下载
- SHA256 校验
- 更新配置和 engine
- 重启 `rtsp_probe.service`
- 状态回传

### 16.2 第二阶段
目标：支持灰度和批量发布

范围：
- 设备分组
- 渠道发布：`stable / canary`
- 并发控制
- 超时与重试

### 16.3 第三阶段
目标：提升生产可用性

范围：
- manifest 签名
- 断点续传
- 断电恢复
- 自动回滚
- 平台可视化升级面板

---

## 17. 与现有系统的对接建议

### 17.1 不建议改动主推理服务职责
当前 `rtsp_probe.service` 专注于：
- 拉流
- 推理
- 上报

远程更新职责建议由独立的：

`update_agent.service`

承担。

### 17.2 平台改造建议
现有平台已有：
- 设备表
- MQTT 基础设施
- 后端 API

可新增：
- 更新任务表
- 设备版本表
- 更新日志表
- 更新任务 API

---

## 18. 风险与对策

### 风险 1：弱网环境导致更新失败
对策：
- 断点续传
- 分块下载
- 下载超时重试

### 风险 2：版本切换后服务起不来
对策：
- 保留 `last_good_version`
- 健康检查失败自动回滚

### 风险 3：模型和程序版本不兼容
对策：
- manifest 中声明兼容矩阵
- 更新前做前置检查

### 风险 4：误下发到错误设备
对策：
- 设备分组
- 确认弹窗
- 灰度发布
- 审计追踪

---

## 19. 推荐最终落地方案

对本项目，建议采用如下组合：

- 控制协议：`MQTT over TLS`
- 下载协议：`HTTPS`
- 维护通道：`WireGuard + SSH`
- Jetson 端：`update_agent.service`
- 更新对象：`app + config + model + engine`
- 版本描述：`manifest.json`
- 切换机制：`release 目录 + current 软链接`
- 容错机制：`last_good_version + 自动回滚`

这是兼顾：
- 可实施性
- 工程可靠性
- 运维便利性
- 野外弱网适应性

的一套方案。

---

## 20. 后续实施建议

建议后续按以下顺序推进：

1. 明确 Jetson 目录结构
2. 定义 MQTT 更新主题
3. 定义 manifest 格式
4. 实现 `update_agent` 最小版本
5. 接入平台更新任务管理
6. 加入回滚与签名校验

---

## 21. 本文档输出结论
对于“实验室远程迭代野外 Jetson 设备中的脚本、模型与配置”这个需求，

**推荐采用 MQTT 作为控制面、HTTPS 作为文件分发、WireGuard+SSH 作为人工维护通道的分层方案。**

其中最核心的工程做法是：

**在 Jetson 上新增独立的 `update_agent`，由它负责拉取 manifest、下载校验、切换版本、重启服务与自动回滚。**
