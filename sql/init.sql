CREATE DATABASE IF NOT EXISTS mf_monitor CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE mf_monitor;

-- Table 1: disaster_data
CREATE TABLE IF NOT EXISTS disaster_data (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  disaster_id VARCHAR(50) NOT NULL,
  aibox_id VARCHAR(50) NOT NULL,
  cam_id VARCHAR(50) NOT NULL,
  disaster_type ENUM('flood','mudslide') NOT NULL,
  `timestamp` DATETIME NOT NULL,
  confidence DECIMAL(5,4) NOT NULL,
  image_path VARCHAR(255) DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_disaster_time (`timestamp`),
  KEY idx_disaster_device_time (aibox_id, cam_id, `timestamp`),
  KEY idx_disaster_aibox_time (aibox_id, `timestamp`),
  KEY idx_disaster_id (disaster_id)
);

-- Table 2: speed_data
CREATE TABLE IF NOT EXISTS speed_data (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  aibox_id VARCHAR(50) NOT NULL,
  cam_id VARCHAR(50) NOT NULL,
  disaster_type ENUM('flood','mudslide') NOT NULL,
  `timestamp` DATETIME NOT NULL,
  speed JSON NOT NULL COMMENT 'speed vector array',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_speed_time (`timestamp`),
  KEY idx_speed_device_time (aibox_id, cam_id, `timestamp`),
  KEY idx_speed_aibox_time (aibox_id, `timestamp`)
);

-- Table 3: device_location
CREATE TABLE IF NOT EXISTS device_location (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  aibox_id VARCHAR(50) NOT NULL,
  cam_id VARCHAR(50) NOT NULL,
  location VARCHAR(200) NOT NULL,
  latitude DECIMAL(10,7) NOT NULL,
  longitude DECIMAL(10,7) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uk_device_location (aibox_id, cam_id)
);

-- Table 4: device_status
CREATE TABLE IF NOT EXISTS device_status (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  aibox_id VARCHAR(50) NOT NULL,
  cam_id VARCHAR(50) NOT NULL,
  online_status ENUM('on','off') NOT NULL,
  last_update DATETIME NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uk_device_status (aibox_id, cam_id),
  KEY idx_status_update (last_update)
);

-- Table 5: devices
CREATE TABLE IF NOT EXISTS devices (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  aibox_id VARCHAR(50) NOT NULL,
  cam_id VARCHAR(50) NOT NULL,
  device_name VARCHAR(100) NOT NULL,
  device_type VARCHAR(50) NOT NULL DEFAULT 'monitor_node',
  enabled TINYINT(1) NOT NULL DEFAULT 1,
  allow_config_push TINYINT(1) NOT NULL DEFAULT 1,
  allow_remote_control TINYINT(1) NOT NULL DEFAULT 0,
  metadata_json JSON DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uk_device_identity (aibox_id, cam_id),
  KEY idx_device_enabled (enabled),
  KEY idx_device_type (device_type),
  KEY idx_device_config_push (allow_config_push)
);

-- Table 6: device_groups
CREATE TABLE IF NOT EXISTS device_groups (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  group_code VARCHAR(64) NOT NULL,
  group_name VARCHAR(100) NOT NULL,
  description VARCHAR(255) DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uk_device_group_code (group_code)
);

-- Table 7: device_group_members
CREATE TABLE IF NOT EXISTS device_group_members (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  group_id BIGINT NOT NULL,
  device_id BIGINT NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_device_group_member (group_id, device_id),
  KEY idx_device_group_device (device_id)
);

-- Table 8: device_commands
CREATE TABLE IF NOT EXISTS device_commands (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  device_id BIGINT NOT NULL,
  aibox_id VARCHAR(50) NOT NULL,
  cam_id VARCHAR(50) NOT NULL,
  command_type VARCHAR(64) NOT NULL DEFAULT 'config_push',
  topic VARCHAR(255) NOT NULL,
  payload_json JSON NOT NULL,
  status ENUM('queued','published','failed') NOT NULL DEFAULT 'queued',
  requested_by VARCHAR(128) NOT NULL,
  requested_at DATETIME NOT NULL,
  published_at DATETIME DEFAULT NULL,
  error_message VARCHAR(500) DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_device_command_device_time (device_id, requested_at),
  KEY idx_device_command_status_time (status, requested_at),
  KEY idx_device_command_identity_time (aibox_id, cam_id, requested_at)
);

-- Table 9: alarm_rules
CREATE TABLE IF NOT EXISTS alarm_rules (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  rule_code VARCHAR(64) NOT NULL,
  name VARCHAR(100) NOT NULL,
  event_type ENUM('classification','speed','device_status') NOT NULL,
  severity ENUM('low','medium','high','critical') NOT NULL DEFAULT 'medium',
  enabled TINYINT(1) NOT NULL DEFAULT 1,
  cooldown_seconds INT NOT NULL DEFAULT 300,
  condition_json JSON NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uk_alarm_rule_code (rule_code),
  KEY idx_alarm_rule_type_enabled (event_type, enabled)
);

-- Table 10: alarms
CREATE TABLE IF NOT EXISTS alarms (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  rule_code VARCHAR(64) NOT NULL,
  event_type ENUM('classification','speed','device_status') NOT NULL,
  severity ENUM('low','medium','high','critical') NOT NULL,
  status ENUM('open','ack','closed') NOT NULL DEFAULT 'open',
  aibox_id VARCHAR(50) NOT NULL,
  cam_id VARCHAR(50) NOT NULL,
  source_ref VARCHAR(80) DEFAULT NULL,
  trigger_value JSON NOT NULL,
  triggered_at DATETIME NOT NULL,
  recovered_at DATETIME DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_alarm_status_time (status, triggered_at),
  KEY idx_alarm_device_time (aibox_id, cam_id, triggered_at),
  KEY idx_alarm_rule_time (rule_code, triggered_at)
);

-- Table 11: notification_channels
CREATE TABLE IF NOT EXISTS notification_channels (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  channel_code VARCHAR(64) NOT NULL,
  name VARCHAR(100) NOT NULL,
  channel_type ENUM('webhook') NOT NULL,
  enabled TINYINT(1) NOT NULL DEFAULT 0,
  retry_max INT NOT NULL DEFAULT 3,
  retry_interval_seconds INT NOT NULL DEFAULT 30,
  timeout_seconds INT NOT NULL DEFAULT 5,
  config_json JSON NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uk_notify_channel_code (channel_code),
  KEY idx_notify_channel_type_enabled (channel_type, enabled)
);

-- Table 12: alarm_notifications
CREATE TABLE IF NOT EXISTS alarm_notifications (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  alarm_id BIGINT NOT NULL,
  channel_id BIGINT NOT NULL,
  channel_code VARCHAR(64) NOT NULL,
  channel_type ENUM('webhook') NOT NULL,
  status ENUM('pending','sent','failed') NOT NULL DEFAULT 'pending',
  attempts INT NOT NULL DEFAULT 0,
  last_error VARCHAR(500) DEFAULT NULL,
  payload_json JSON NOT NULL,
  next_retry_at DATETIME DEFAULT NULL,
  last_attempt_at DATETIME DEFAULT NULL,
  sent_at DATETIME DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uk_alarm_channel_notification (alarm_id, channel_id),
  KEY idx_alarm_notify_status_retry (status, next_retry_at),
  KEY idx_alarm_notify_channel (channel_code, status),
  KEY idx_alarm_notify_alarm (alarm_id)
);

-- Table 13: audit_logs
CREATE TABLE IF NOT EXISTS audit_logs (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  request_id VARCHAR(64) NOT NULL,
  actor_type VARCHAR(32) NOT NULL,
  actor_id VARCHAR(128) NOT NULL,
  action VARCHAR(64) NOT NULL,
  outcome VARCHAR(16) NOT NULL,
  entity_type VARCHAR(64) DEFAULT NULL,
  entity_id VARCHAR(64) DEFAULT NULL,
  path VARCHAR(255) NOT NULL,
  method VARCHAR(16) NOT NULL,
  status_code INT DEFAULT NULL,
  client_ip VARCHAR(64) DEFAULT NULL,
  detail_json JSON DEFAULT NULL,
  before_json JSON DEFAULT NULL,
  after_json JSON DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_audit_created_at (created_at),
  KEY idx_audit_request_id (request_id),
  KEY idx_audit_action (action),
  KEY idx_audit_entity (entity_type, entity_id),
  KEY idx_audit_path (path),
  KEY idx_audit_outcome (outcome)
);


-- Table 14: platform_users
CREATE TABLE IF NOT EXISTS platform_users (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  username VARCHAR(64) NOT NULL,
  display_name VARCHAR(100) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  role ENUM('admin','operator','viewer') NOT NULL DEFAULT 'viewer',
  enabled TINYINT(1) NOT NULL DEFAULT 1,
  last_login_at DATETIME DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uk_platform_user_username (username),
  KEY idx_platform_user_role_enabled (role, enabled)
);

-- Table 15: platform_sessions
CREATE TABLE IF NOT EXISTS platform_sessions (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  user_id BIGINT NOT NULL,
  token_hash CHAR(64) NOT NULL,
  client_ip VARCHAR(64) DEFAULT NULL,
  user_agent VARCHAR(255) DEFAULT NULL,
  expires_at DATETIME NOT NULL,
  revoked_at DATETIME DEFAULT NULL,
  last_used_at DATETIME DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uk_platform_session_token_hash (token_hash),
  KEY idx_platform_session_user (user_id),
  KEY idx_platform_session_expire (expires_at),
  KEY idx_platform_session_revoked (revoked_at)
);
-- Archive tables for lifecycle governance
CREATE TABLE IF NOT EXISTS disaster_data_archive LIKE disaster_data;
CREATE TABLE IF NOT EXISTS speed_data_archive LIKE speed_data;
CREATE TABLE IF NOT EXISTS alarms_archive LIKE alarms;
CREATE TABLE IF NOT EXISTS alarm_notifications_archive LIKE alarm_notifications;
CREATE TABLE IF NOT EXISTS audit_logs_archive LIKE audit_logs;
-- archived_at column is ensured by scripts/archive_cold_data.ps1 at runtime.

-- Seed data for API integration test
UPDATE device_location
SET
  location = 'XX监测点',
  latitude = 34.0500000,
  longitude = 118.0500000
WHERE aibox_id = 'MF001' AND cam_id = 'CAM001';

INSERT INTO device_location (aibox_id, cam_id, location, latitude, longitude)
SELECT 'MF001', 'CAM001', 'XX监测点', 34.0500000, 118.0500000
WHERE NOT EXISTS (
  SELECT 1 FROM device_location WHERE aibox_id = 'MF001' AND cam_id = 'CAM001'
);

UPDATE device_status
SET
  online_status = 'on',
  last_update = '2026-05-07 21:05:00'
WHERE aibox_id = 'MF001' AND cam_id = 'CAM001';

INSERT INTO device_status (aibox_id, cam_id, online_status, last_update)
SELECT 'MF001', 'CAM001', 'on', '2026-05-07 21:05:00'
WHERE NOT EXISTS (
  SELECT 1 FROM device_status WHERE aibox_id = 'MF001' AND cam_id = 'CAM001'
);

INSERT INTO devices (aibox_id, cam_id, device_name, device_type, enabled, allow_config_push, allow_remote_control, metadata_json)
VALUES (
  'MF001',
  'CAM001',
  '1号监测点',
  'monitor_node',
  1,
  1,
  0,
  JSON_OBJECT('project_name', '山洪泥石流监测', 'site_code', 'MF001', 'site_name', 'XX监测点')
)
ON DUPLICATE KEY UPDATE
  device_name = VALUES(device_name),
  device_type = VALUES(device_type),
  enabled = VALUES(enabled),
  allow_config_push = VALUES(allow_config_push),
  allow_remote_control = VALUES(allow_remote_control),
  metadata_json = VALUES(metadata_json);

INSERT INTO device_groups (group_code, group_name, description)
VALUES ('DEFAULT', '默认分组', '客户端 API 联调默认分组')
ON DUPLICATE KEY UPDATE
  group_name = VALUES(group_name),
  description = VALUES(description);

INSERT IGNORE INTO device_group_members (group_id, device_id)
SELECT g.id, d.id
FROM device_groups g
JOIN devices d
  ON d.aibox_id = 'MF001' AND d.cam_id = 'CAM001'
WHERE g.group_code = 'DEFAULT';

INSERT INTO disaster_data (disaster_id, aibox_id, cam_id, disaster_type, timestamp, confidence, image_path)
SELECT '20260507_001', 'MF001', 'CAM001', 'mudslide', '2026-05-07 21:02:00', 0.9300, '/evidence/MF001/CAM001/20260507_001.jpg'
WHERE NOT EXISTS (
  SELECT 1 FROM disaster_data WHERE disaster_id = '20260507_001'
);

INSERT INTO disaster_data (disaster_id, aibox_id, cam_id, disaster_type, timestamp, confidence, image_path)
SELECT '20260507_002', 'MF001', 'CAM001', 'flood', '2026-05-07 21:06:00', 0.9560, '/evidence/MF001/CAM001/20260507_002.jpg'
WHERE NOT EXISTS (
  SELECT 1 FROM disaster_data WHERE disaster_id = '20260507_002'
);

INSERT INTO speed_data (aibox_id, cam_id, disaster_type, timestamp, speed)
SELECT
  'MF001',
  'CAM001',
  'mudslide',
  '2026-05-07 21:03:00',
  JSON_OBJECT(
    'avg_speed', 1.58,
    'max_speed', 1.72,
    'unit', 'm/s',
    'sample_count', 3,
    'series', JSON_ARRAY(1.46, 1.55, 1.72)
  )
WHERE NOT EXISTS (
  SELECT 1
  FROM speed_data
  WHERE aibox_id = 'MF001'
    AND cam_id = 'CAM001'
    AND disaster_type = 'mudslide'
    AND timestamp = '2026-05-07 21:03:00'
);

INSERT INTO speed_data (aibox_id, cam_id, disaster_type, timestamp, speed)
SELECT
  'MF001',
  'CAM001',
  'flood',
  '2026-05-07 21:07:00',
  JSON_OBJECT(
    'avg_speed', 1.86,
    'max_speed', 2.14,
    'unit', 'm/s',
    'sample_count', 3,
    'series', JSON_ARRAY(1.72, 1.86, 2.14)
  )
WHERE NOT EXISTS (
  SELECT 1
  FROM speed_data
  WHERE aibox_id = 'MF001'
    AND cam_id = 'CAM001'
    AND disaster_type = 'flood'
    AND timestamp = '2026-05-07 21:07:00'
);

-- Seed default rules
INSERT INTO alarm_rules (rule_code, name, event_type, severity, enabled, cooldown_seconds, condition_json)
VALUES
  ('cls_high_conf_flood', 'Flood high confidence', 'classification', 'high', 1, 300, JSON_OBJECT('disaster_type','flood','min_confidence',0.9)),
  ('speed_high_avg', 'Speed average high', 'speed', 'medium', 1, 120, JSON_OBJECT('min_avg_speed',1.8)),
  ('device_offline', 'Device offline', 'device_status', 'high', 1, 60, JSON_OBJECT('online_status','off'))
ON DUPLICATE KEY UPDATE
  name = VALUES(name),
  event_type = VALUES(event_type),
  severity = VALUES(severity),
  enabled = VALUES(enabled),
  cooldown_seconds = VALUES(cooldown_seconds),
  condition_json = VALUES(condition_json);

-- Seed default notification channel (disabled)
INSERT INTO notification_channels (
  channel_code,
  name,
  channel_type,
  enabled,
  retry_max,
  retry_interval_seconds,
  timeout_seconds,
  config_json
)
VALUES (
  'default_webhook',
  'Default Webhook (disabled)',
  'webhook',
  0,
  3,
  30,
  5,
  JSON_OBJECT('url','', 'headers', JSON_OBJECT())
)
ON DUPLICATE KEY UPDATE
  name = VALUES(name),
  channel_type = VALUES(channel_type),
  enabled = VALUES(enabled),
  retry_max = VALUES(retry_max),
  retry_interval_seconds = VALUES(retry_interval_seconds),
  timeout_seconds = VALUES(timeout_seconds),
  config_json = VALUES(config_json);




