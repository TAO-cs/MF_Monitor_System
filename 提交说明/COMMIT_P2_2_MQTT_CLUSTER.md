# COMMIT_P2_2_MQTT_CLUSTER.md

## 变更目标
完成 P2-2「MQTT 集群化」基线：从单 Broker 升级为主备 Broker + 代理入口，并补齐故障切换与监控验收。

## 主要改动
- 新增 MQTT 集群编排文件：`docker-compose.p2-mqtt.yml`
- 新增 HAProxy 配置：`mqtt/cluster/haproxy.cfg`
- 新增双 Broker 配置：
  - `mqtt/cluster/node1/mosquitto.conf`
  - `mqtt/cluster/node2/mosquitto.conf`
- 新增启动/停止脚本：
  - `scripts/start_p2_2_mqtt_cluster.ps1`
  - `scripts/stop_p2_2_mqtt_cluster.ps1`
- 新增验收脚本：`test/verify_p2_2_mqtt_cluster.ps1`
- 新增阶段说明：`P2_2_MQTT_CLUSTER.md`
- 修复 MQTT 回调兼容问题：`backend/app/mqtt_service.py`
  - 修正 `on_disconnect` 为 paho-mqtt v2 签名，避免消费线程崩溃
- 更新路线状态：`生产级平台.md`（P2-2 勾选完成）

## 设计要点
- `mf_mqtt` 由 Mosquitto 切换为 HAProxy，保持入口地址不变（1883/9001）。
- `mqtt_primary` 主用，`mqtt_secondary` 备份（`backup`），避免双活消息分裂风险。
- 后端仍只连 `mqtt:1883`，无需改业务 Topic。
- 通过 `$SYS` 主题验证连接数、吞吐量、堆积量：
  - `$SYS/broker/clients/connected`
  - `$SYS/broker/messages/received`
  - `$SYS/broker/messages/stored`

## 验收命令
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_p2_2_mqtt_cluster.ps1 -Env dev
powershell -ExecutionPolicy Bypass -File .\test\verify_p2_2_mqtt_cluster.ps1 -EnvFile .env.dev.ha.mqtt
```

## 验收结果（本次）
- 容器角色检查通过
- 代理发布写库通过
- 主节点监控主题读取通过
- 停主后自动切换并恢复消费通过
- 故障期间继续写库通过
- 备节点监控主题读取通过
- `mf_mqtt_messages_total` 吞吐指标递增通过

## 回滚说明
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop_p2_2_mqtt_cluster.ps1 -Env dev
powershell -ExecutionPolicy Bypass -File .\scripts\start_p2_1_backend_ha.ps1 -Env dev
```

回滚后将恢复到 P2-1（单 MQTT Broker）架构。
