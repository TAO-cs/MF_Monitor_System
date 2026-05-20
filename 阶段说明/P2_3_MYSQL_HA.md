# P2-3 MySQL 高可用（主从复制 + 手动提升）

## 目标
- 消除单 MySQL 节点故障风险。
- 建立主从复制（Primary + Replica）并保持后端可读写主库。
- 提供手动提升（Replica Promote）能力，形成故障切换策略基础。

## 方案
- 主库：`mf_mysql`（对外 3307，对内 mysql:3306）
- 从库：`mf_mysql_replica`（对外 3308，对内 mysql_replica:3306）
- 复制模式：GTID + 异步复制
- 主库开启 binlog；从库默认只读（`read_only=ON`,`super_read_only=ON`）

## 新增文件
- `docker-compose.p2-mysql-ha.yml`
- `scripts/start_p2_3_mysql_ha.ps1`
- `scripts/stop_p2_3_mysql_ha.ps1`
- `scripts/promote_mysql_replica.ps1`
- `test/verify_p2_3_mysql_ha.ps1`

## 启动
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_p2_3_mysql_ha.ps1 -Env dev
```

运行时会自动生成环境文件：
- `.env.dev.ha.mqtt.dbha`

并自动完成：
- 主库复制用户创建
- 从库复制源配置
- 复制线程启动和就绪检查

## 验收
```powershell
powershell -ExecutionPolicy Bypass -File .\test\verify_p2_3_mysql_ha.ps1 -EnvFile .env.dev.ha.mqtt.dbha
```

验收覆盖：
- 容器状态检查
- 网关/API 健康检查
- 复制线程状态（IO/SQL=ON）
- 从库只读状态检查
- 主库写入 marker，并验证从库同步到达

## 手动故障切换（提升从库）
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\promote_mysql_replica.ps1 -Env dev -GeneratePromotedEnv
```

执行后会：
- 停止并重置复制
- 关闭只读，使从库可写
- 生成 `*.promoted` 环境文件用于后端切换到 `mysql_replica`

## 停止
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop_p2_3_mysql_ha.ps1 -Env dev
```
