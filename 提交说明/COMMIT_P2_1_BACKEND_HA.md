# Commit Note - P2-1 Backend HA Baseline

## Scope
This commit packages the P2-1 backend high-availability baseline implementation.

## Suggested Commit Subject
feat(p2-1): implement backend HA baseline with dual API nodes and dedicated ingestion worker

## Suggested Commit Body
- add backend container image build file and HA compose overlay
- deploy two API instances behind Nginx upstream load balancing
- deploy one dedicated backend worker for MQTT ingestion + notification processing
- make API instances stateless for ingestion path (`ENABLE_INGESTION=0`)
- expose instance identity in API responses (`X-Backend-Instance`) and `/health`
- add startup role logs and safer MQTT client-id naming (instance + PID)
- add HA Nginx config with upstream failover behavior
- add P2-1 start/stop scripts and end-to-end acceptance script
- fix startup script to generate `.env.<env>.ha` runtime env file
- fix Nginx duplicate-config issue by moving HA config mount out of `nginx/conf.d`

## Main Files
- `backend/app/config.py`
- `backend/app/main.py`
- `backend/app/mqtt_service.py`
- `backend/Dockerfile`
- `docker-compose.p2-ha.yml`
- `nginx/ha/default_ha.conf`
- `scripts/start_p2_1_backend_ha.ps1`
- `scripts/stop_p2_1_backend_ha.ps1`
- `test/verify_p2_1_backend_ha.ps1`
- `P2_1_BACKEND_HA.md`

## Acceptance Result
Executed and passed:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_p2_1_backend_ha.ps1 -Env dev
powershell -ExecutionPolicy Bypass -File .\test\verify_p2_1_backend_ha.ps1 -EnvFile .env.dev.ha
```

Observed result:
- `[7/7] PASS: P2-1 backend HA baseline works`
- failover drill passed (stop `backend_api_1`, gateway still served by `backend_api_2`)
- ingestion role split verified (`api1=0, api2=0, worker=1`)

## Rollback Plan
1. Stop HA overlay stack:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop_p2_1_backend_ha.ps1 -Env dev
```
2. Revert P2-1 files listed above.
3. Start previous baseline stack (`scripts/start.ps1`) and re-run smoke checks.

## Notes
- If Docker Hub is unreachable, set `BACKEND_BASE_IMAGE` in `.env.dev` to an accessible mirror image.
- Runtime HA env file is generated as `<EnvFile>.ha`, e.g. `.env.dev.ha`.