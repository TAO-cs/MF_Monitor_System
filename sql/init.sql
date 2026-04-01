CREATE DATABASE IF NOT EXISTS mf_monitor CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE mf_monitor;

CREATE TABLE IF NOT EXISTS devices (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  device_code VARCHAR(64) NOT NULL UNIQUE,
  name VARCHAR(128) NOT NULL,
  device_type VARCHAR(64) DEFAULT 'sensor',
  location VARCHAR(255) DEFAULT NULL,
  is_active TINYINT(1) NOT NULL DEFAULT 1,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS device_status (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  device_code VARCHAR(64) NOT NULL,
  is_online TINYINT(1) NOT NULL DEFAULT 0,
  last_seen_at DATETIME DEFAULT NULL,
  battery_level DECIMAL(5,2) DEFAULT NULL,
  signal_strength INT DEFAULT NULL,
  raw_payload JSON DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uk_device_status_code (device_code)
);

CREATE TABLE IF NOT EXISTS telemetry_data (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  device_code VARCHAR(64) NOT NULL,
  event_time DATETIME NOT NULL,
  metric_key VARCHAR(64) NOT NULL,
  metric_value DOUBLE NOT NULL,
  unit VARCHAR(32) DEFAULT NULL,
  trace_id VARCHAR(64) DEFAULT NULL,
  raw_payload JSON DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_telemetry_device_time (device_code, event_time),
  KEY idx_telemetry_metric (metric_key)
);

CREATE TABLE IF NOT EXISTS alarms (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  device_code VARCHAR(64) NOT NULL,
  alarm_type VARCHAR(64) NOT NULL,
  level VARCHAR(16) NOT NULL,
  message VARCHAR(255) NOT NULL,
  event_time DATETIME NOT NULL,
  is_cleared TINYINT(1) NOT NULL DEFAULT 0,
  raw_payload JSON DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_alarm_device_time (device_code, event_time)
);

CREATE TABLE IF NOT EXISTS command_logs (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  device_code VARCHAR(64) NOT NULL,
  command_name VARCHAR(64) NOT NULL,
  request_payload JSON DEFAULT NULL,
  response_payload JSON DEFAULT NULL,
  status VARCHAR(32) NOT NULL DEFAULT 'SENT',
  trace_id VARCHAR(64) DEFAULT NULL,
  sent_at DATETIME NOT NULL,
  responded_at DATETIME DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_cmd_device_time (device_code, sent_at)
);

INSERT INTO devices (device_code, name, device_type, location)
VALUES ('DEV-001', '演示设备1', 'rainfall_sensor', '测试点A')
ON DUPLICATE KEY UPDATE name = VALUES(name);
