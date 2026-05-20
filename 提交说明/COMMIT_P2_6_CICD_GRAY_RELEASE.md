# COMMIT_P2_6_CICD_GRAY_RELEASE.md

## 变更目标
完成 P2-6「CI/CD 与灰度发布」第一版工程落地：提供本地 CI 校验脚本、GitHub Actions 工作流、Canary 灰度发布、灰度转正、快速回滚能力，并在 HA 网关下完成端到端验收。

## 新增内容
- `.github/workflows/p2_6_ci.yml`
  - 新增 GitHub Actions CI 工作流
  - 覆盖 Python 依赖安装、本地 CI 校验、后端镜像构建
- `scripts/run_ci_local.ps1`
  - 新增本地 CI 基线脚本
  - 覆盖环境校验、Python 语法编译、PowerShell 解析、Docker 镜像构建
  - 支持离线环境下回退到本地已有后端镜像完成构建验证
- `scripts/deploy_canary_release.ps1`
  - 新增 Canary 灰度发布脚本
- `scripts/promote_canary_release.ps1`
  - 新增灰度转正脚本
- `scripts/rollback_canary_release.ps1`
  - 新增快速回滚脚本
- `scripts/p2_6_release_utils.ps1`
  - 新增 P2-6 发布辅助函数脚本
- `test/verify_p2_6_cicd.ps1`
  - 新增 P2-6 一键验收脚本
  - 覆盖 CI、灰度发布、转正、回滚全流程

## 主要改动
- `backend/app/config.py`
  - 新增 `app_release_version`
  - 新增 `app_release_channel`
- `backend/app/main.py`
  - 在响应头中新增 `X-Release-Version`
  - 在响应头中新增 `X-Release-Channel`
  - 在 `/health` 中新增 `release_version`
  - 在 `/health` 中新增 `release_channel`
- `docker-compose.p2-ha.yml`
  - 为 `backend_api_1`、`backend_api_2`、`backend_worker` 注入发布通道与版本变量
- `nginx/ha/default_ha.conf`
  - 新增基于 `X-Release-Channel` 的灰度路由能力
  - 默认流量走 stable，带 `X-Release-Channel: canary` 时走 canary
- `scripts/start_p2_1_backend_ha.ps1`
- `scripts/start_p2_2_mqtt_cluster.ps1`
- `scripts/start_p2_3_mysql_ha.ps1`
  - 补充发布版本默认值
  - 补充离线基础镜像回退逻辑

## 新增能力
- 本地 CI 一键校验
- GitHub Actions 自动校验
- Stable / Canary 双节点版本并存
- Header 级灰度路由
- 灰度转正
- 快速回滚
- 离线环境下的本地镜像构建回退

## 验收命令
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_ci_local.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start_p2_3_mysql_ha.ps1 -Env dev
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_p2_6_cicd.ps1 -EnvFile .env.dev.ha.mqtt.dbha
```

## 验收结果
- 本地 CI 校验通过
- 灰度发布后，带 `X-Release-Channel: canary` 的流量命中 canary 节点
- 默认流量稳定命中 stable 节点
- 灰度转正后 stable 节点切换到新版本
- 回滚后 stable / canary 节点恢复到旧版本
- 最终验收结果：`PASS: P2-6 CI/CD and gray release baseline works`

## 关键问题与修复
- 修复了后端未暴露发布版本与通道信息的问题
- 修复了 HA 网关灰度路由配置问题
- 修复了 Docker Hub 不可达时本地 CI 无法构建的问题
- 修复了发布过程中容器重建后 Nginx 仍持有旧 upstream 解析结果的问题
  - 解决方式：在发布辅助函数中，相关服务更新后主动重启 `mf_nginx`

## 回滚
如需回退到不含 P2-6 能力的状态，可回滚以下文件：
- `.github/workflows/p2_6_ci.yml`
- `scripts/run_ci_local.ps1`
- `scripts/deploy_canary_release.ps1`
- `scripts/promote_canary_release.ps1`
- `scripts/rollback_canary_release.ps1`
- `scripts/p2_6_release_utils.ps1`
- `backend/app/config.py`
- `backend/app/main.py`
- `docker-compose.p2-ha.yml`
- `nginx/ha/default_ha.conf`
- `test/verify_p2_6_cicd.ps1`

回滚后重新启动 HA 栈并重载 Nginx 配置即可。