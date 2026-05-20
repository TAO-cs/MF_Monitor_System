# P2-2 MQTT 集群化（主备 + 代理）

## 目标
- 消除单 MQTT Broker 单点风险。
- 在不改业务发布主题的前提下，实现 Broker 故障自动切换。
- 补齐连接数、吞吐量、堆积量三类监控入口。

## 方案
- `mqtt_primary` + `mqtt_secondary`：双 Mosquitto 节点。
- `mqtt`（`mf_mqtt`）改为 HAProxy 统一入口：
  - 主节点优先（`mqtt_primary`）
  - 备节点接管（`mqtt_secondary` backup）
- 后端仍连接单地址：`MQTT_BROKER_HOST=mqtt`, `MQTT_BROKER_PORT=1883`。

## 新增文件
- `docker-compose.p2-mqtt.yml`
- `mqtt/cluster/haproxy.cfg`
- `mqtt/cluster/node1/mosquitto.conf`
- `mqtt/cluster/node2/mosquitto.conf`
- `scripts/start_p2_2_mqtt_cluster.ps1`
- `scripts/stop_p2_2_mqtt_cluster.ps1`
- `test/verify_p2_2_mqtt_cluster.ps1`

## 启动
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_p2_2_mqtt_cluster.ps1 -Env dev
```

启动后关键端口：
- MQTT 代理：`127.0.0.1:1883`
- MQTT 代理 WebSocket：`127.0.0.1:9001`
- HAProxy 统计：`http://127.0.0.1:8404/stats`
- 主节点直连：`127.0.0.1:1884`
- 备节点直连：`127.0.0.1:1885`

## 验收
```powershell
powershell -ExecutionPolicy Bypass -File .\test\verify_p2_2_mqtt_cluster.ps1 -EnvFile .env.dev.ha.mqtt
```

验收脚本覆盖：
- 容器状态与角色分离检查
- 通过代理发布消息并落库验证
- 主节点 `$SYS` 监控主题验证
- 停主节点后 worker 自动重连验证
- 故障期间继续发布并落库验证
- 备节点 `$SYS` 监控主题验证
- `mf_mqtt_messages_total` 吞吐计数递增验证

## 停止
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop_p2_2_mqtt_cluster.ps1 -Env dev
```
