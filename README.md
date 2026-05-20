# MF Monitor System - 闆忓舰鑴氭湰

杩欎釜闆忓舰瀹炵幇浜嗕綘褰撳墠闃舵鏈€鍏抽敭鐨勪袱鏉′富绾匡細
- MySQL 鎸佷箙鍖栧瓨鍌?
- MQTT 瀹炴椂娑堟伅鎺ュ叆涓庢秷璐瑰叆搴?

## 1. 浣犻渶瑕佸畨瑁呯殑杞欢

1. Docker Desktop (寤鸿 4.x 浠ヤ笂)
2. Python 3.11+ (寤鸿 3.11/3.12)
3. Git (鍙€?
4. MySQL 瀹㈡埛绔伐鍏?(鍙€夛紝鎺ㄨ崘 DBeaver 鎴?Navicat)
5. MQTT 瀹㈡埛绔伐鍏?(鍙€夛紝鎺ㄨ崘 MQTTX)

## 2. 鐩綍缁撴瀯

```text
MF_Monitor_System/
  backend/
    app/
      main.py
      config.py
      db.py
      models.py
      schemas.py
      mqtt_service.py
    requirements.txt
    simulator.py
  mqtt/
    mosquitto.conf
  scripts/
    start.ps1
    stop.ps1
    run_backend.ps1
    run_simulator.ps1
  sql/
    init.sql
  docker-compose.yml
  .env.example
```

## 3. 蹇€熷惎鍔?

### 3.1 鍚姩 MySQL + MQTT

鍦ㄩ」鐩牴鐩綍鎵ц锛?

```powershell
Copy-Item .env.example .env
.\scripts\start.ps1
```

### 3.2 鍚姩鍚庣鏈嶅姟

```powershell
.\scripts\run_backend.ps1
```

### 3.3 鍚姩妯℃嫙璁惧涓婃姤

鏂板紑涓€涓粓绔細

```powershell
.\scripts\run_simulator.ps1 -Device DEV-001 -Interval 3
```

## 4. 鍙洿鎺ョ敤鐨勬帴鍙?

1. 鍋ュ悍妫€鏌?
```http
GET http://127.0.0.1:8000/health
```

2. 鍒涘缓璁惧
```http
POST http://127.0.0.1:8000/devices
Content-Type: application/json

{
  "device_code": "DEV-002",
  "name": "婕旂ず璁惧2",
  "device_type": "rainfall_sensor",
  "location": "娴嬭瘯鐐笲"
}
```

3. 璁惧鍒楄〃
```http
GET http://127.0.0.1:8000/devices
```

4. 鏈€杩戦仴娴嬫暟鎹?
```http
GET http://127.0.0.1:8000/telemetry/latest?limit=20
```

5. 涓嬪彂鍛戒护锛圡QTT锛?
```http
POST http://127.0.0.1:8000/commands/send
Content-Type: application/json

{
  "device_code": "DEV-001",
  "command_name": "reboot",
  "payload": {
    "delay": 5
  }
}
```

## 5. MQTT Topic 瑙勮寖锛堝綋鍓嶉洀褰級

- 涓婃姤閬ユ祴: `mf/{device_id}/telemetry`
- 璁惧鐘舵€? `mf/{device_id}/status`
- 涓嬪彂鍛戒护璇锋眰: `mf/{device_id}/command/req`
- 鍛戒护搴旂瓟: `mf/{device_id}/command/resp`

## 6. 鍋滄鐜

```powershell
.\scripts\stop.ps1
```

## 7. 璇存槑

- `sql/init.sql` 浼氬湪 MySQL 棣栨鍚姩鏃惰嚜鍔ㄥ缓搴撳缓琛ㄣ€?
- 鍚庣鍦ㄥ惎鍔ㄦ椂浼氳嚜鍔ㄨ繛鎺?MQTT 骞惰闃?`mf/+/telemetry` 鍜?`mf/+/status`銆?
- 鏀跺埌娑堟伅鍚庝細灏?metrics 鎷嗗垎钀藉簱鍒?`telemetry_data`锛屽苟鏇存柊 `device_status`銆?

## 8. Vue 鍓嶇鎺у埗鍙?
褰撳墠椤圭洰宸茬粡鏂板 Vue 骞冲彴鍓嶇锛岀敓浜у叆鍙ｄ负锛?
```text
https://127.0.0.1/console
```

鏈湴寮€鍙戝懡浠わ細

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_frontend.ps1
```

鐢熶骇鏋勫缓鍛戒护锛?
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_frontend.ps1
```

璇存槑锛?- `frontend/` 鏄柊鐨?Vue 宸ョ▼鐩綍銆?- `scripts/build_frontend.ps1` 浼氬厛鏋勫缓 `frontend/dist`锛屽啀鍚屾鍒?`backend/frontend_dist/`銆?- 鍚庣閫氳繃 `/console` 鎻愪緵鍓嶇闈欐€佹枃浠讹紝鏃х増 `/dashboard` 淇濈暀鐢ㄤ簬骞虫粦杩佺Щ銆
Vue 前端当前已经按模块拆分为：
- `router/` 路由层
- `layouts/` 平台布局层
- `composables/` 共享数据层
- `shared/components/` 共享组件层
- `modules/*` 业务模块层

这样后续可以按模块单独优化，不需要再在一个大页面里堆所有逻辑。

## 9. 生产环境凭据约定

- 平台管理员账号：从部署环境变量 `PLATFORM_ADMIN_USERNAME` 读取
- 平台管理员密码：从部署环境变量 `PLATFORM_ADMIN_PASSWORD` 读取
- API 访问密钥：从部署环境变量 `API_KEY` / `API_KEYS` 读取
- 仓库中不保存可直接上线使用的默认口令或默认 API Key
