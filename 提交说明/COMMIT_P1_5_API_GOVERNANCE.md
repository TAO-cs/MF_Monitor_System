# Commit Note - P1-5 API Governance

## Scope
This commit note packages the current P1-5 API governance changes only.

## Suggested Commit Subject
feat(api): add API governance baseline (pagination, unified errors, idempotency, rate limiting)

## Suggested Commit Body
- add pagination support for list APIs with `paginate/page/page_size`
- keep backward compatibility when `paginate=false`
- add unified error response structure: `code/message/detail/request_id`
- add explicit auth error codes: `AUTH_MISSING_HEADER`, `AUTH_BAD_FORMAT`, `AUTH_INVALID_KEY`
- add in-memory request rate limiting for `/api/*` and return `RATE_LIMIT_EXCEEDED`
- add in-memory idempotency support for mutating `/api/*` with `Idempotency-Key`
- return replay response for same key+same payload
- return `IDEMPOTENCY_KEY_REUSE_CONFLICT` for same key+different payload
- extend env-based governance settings (rate limit + idempotency)
- add P1-5 acceptance script and fix PS error-body parsing compatibility

## Main Files
- `backend/app/main.py`
- `backend/app/config.py`
- `test/verify_p1_5_api_governance.ps1`

## API Behavior Changes
1. Pagination (opt-in)
- request: `GET /api/classification?paginate=true&page=1&page_size=20`
- response shape: `{ "items": [...], "total": N, "page": 1, "page_size": 20 }`

2. Unified errors
- example 401 response:
```json
{
  "code": "AUTH_MISSING_HEADER",
  "message": "Missing Authorization header",
  "detail": "Missing Authorization header",
  "request_id": "..."
}
```

3. Idempotency for mutating APIs
- header: `Idempotency-Key: <key>`
- same key + same payload: replay previous success response
- same key + different payload: `409 IDEMPOTENCY_KEY_REUSE_CONFLICT`

4. Rate limiting for `/api/*`
- exceeded requests in window: `429 RATE_LIMIT_EXCEEDED`

## New/Used Env Variables
- `RATE_LIMIT_ENABLED`
- `RATE_LIMIT_WINDOW_SECONDS`
- `RATE_LIMIT_MAX_REQUESTS`
- `IDEMPOTENCY_ENABLED`
- `IDEMPOTENCY_TTL_SECONDS`
- `IDEMPOTENCY_MAX_ENTRIES`
- `IDEMPOTENCY_MAX_BODY_BYTES`

## Validation Performed
- syntax check:
  - `python -m py_compile backend/app/main.py backend/app/config.py`
- acceptance test:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\test\verify_p1_5_api_governance.ps1 -EnvFile .env.dev`
- observed result:
  - `[6/6] PASS: P1-5 API governance works`

## Rollback Plan
1. revert these files:
- `backend/app/main.py`
- `backend/app/config.py`
- `test/verify_p1_5_api_governance.ps1`
2. restart backend service
3. rerun smoke checks (`/health`, `/api/device_status`)

## Notes
- This note is scoped to P1-5 and does not include other unrelated local workspace changes.