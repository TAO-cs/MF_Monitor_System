#!/usr/bin/env bash
set -euo pipefail

SITE_CODE="${1:?site code required}"
PACKAGE_ROOT="${2:-$(pwd)}"
APP_SOURCE_ROOT="${APP_SOURCE_ROOT:-${PACKAGE_ROOT}/jetson_edge_disnet_cpp}"
CONFIG_SOURCE="${PACKAGE_ROOT}/config/device.ini"
TARGET_ROOT="/opt/mf-monitor/${SITE_CODE}"
SERVICE_FILE="/etc/systemd/system/rtsp_probe@${SITE_CODE}.service"
SERVICE_TEMPLATE="${APP_SOURCE_ROOT}/deploy/rtsp_probe@.service"

if [[ ! -d "${APP_SOURCE_ROOT}" ]]; then
    echo "[install] jetson source directory not found: ${APP_SOURCE_ROOT}" >&2
    exit 1
fi

if [[ ! -f "${CONFIG_SOURCE}" ]]; then
    echo "[install] rendered config not found: ${CONFIG_SOURCE}" >&2
    exit 1
fi

if [[ ! -f "${SERVICE_TEMPLATE}" ]]; then
    echo "[install] service template not found: ${SERVICE_TEMPLATE}" >&2
    exit 1
fi

mkdir -p "${TARGET_ROOT}"
cp -r "${APP_SOURCE_ROOT}" "${TARGET_ROOT}/jetson_edge_disnet_cpp"
mkdir -p "${TARGET_ROOT}/config"
cp "${CONFIG_SOURCE}" "${TARGET_ROOT}/config/device.ini"
cp "${SERVICE_TEMPLATE}" "${SERVICE_FILE}"
systemctl daemon-reload
systemctl enable "rtsp_probe@${SITE_CODE}.service"
