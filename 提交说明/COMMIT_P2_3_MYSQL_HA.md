# COMMIT_P2_3_MYSQL_HA.md

## 变更目标
完成 P2-3「MySQL 高可用」第一版工程落地：主从复制、自动配置、验收脚本、手动提升流程。

## 新增内容
- `docker-compose.p2-mysql-ha.yml`
  - 主库增强：binlog + GTID + healthcheck
  - 新增从库 `mf_mysql_replica`（3308），默认只读
- `scripts/start_p2_3_mysql_ha.ps1`
  - 生成运行时 env：`<env>.ha.mqtt.dbha`
  - 拉起 P2-1 + P2-2 + P2-3 组合栈
  - 自动创建复制账号
  - 自动配置并启动复制
  - 等待复制线程就绪
- `scripts/stop_p2_3_mysql_ha.ps1`
  - 一键停止 P2-3 组合栈
- `scripts/promote_mysql_replica.ps1`
  - 手动提升从库为可写节点
  - 可生成 `.promoted` 环境文件用于后端切换
- `test/verify_p2_3_mysql_ha.ps1`
  - 复制状态、只读状态、数据同步链路验收
- `P2_3_MYSQL_HA.md`

## 关键策略
- 主写从读（当前后端仍写主库）
- GTID 自动定位（`SOURCE_AUTO_POSITION=1`）
- 从库默认严格只读，避免误写
- 提供明确的人工故障切换脚本

## 验收命令
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_p2_3_mysql_ha.ps1 -Env dev
powershell -ExecutionPolicy Bypass -File .\test\verify_p2_3_mysql_ha.ps1 -EnvFile .env.dev.ha.mqtt.dbha
```

## 回滚
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop_p2_3_mysql_ha.ps1 -Env dev
powershell -ExecutionPolicy Bypass -File .\scripts\start_p2_2_mqtt_cluster.ps1 -Env dev
```

回滚后恢复到 P2-2（单主 MySQL）架构。
