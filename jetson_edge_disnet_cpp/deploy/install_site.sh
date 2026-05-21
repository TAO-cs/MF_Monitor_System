#!/usr/bin/env bash
set -euo pipefail

SITE_CODE="${1:?site code required}"
PACKAGE_ROOT="${2:-$(pwd)}"
RELEASE_VERSION="${3:-}"
APP_SOURCE_ROOT="${APP_SOURCE_ROOT:-${PACKAGE_ROOT}/jetson_edge_disnet_cpp}"
CONFIG_SOURCE="${PACKAGE_ROOT}/config/device.ini"
MANIFEST_SOURCE="${PACKAGE_ROOT}/site-manifest.json"
SITE_ROOT="/opt/mf-monitor/${SITE_CODE}"
RELEASES_ROOT="${SITE_ROOT}/releases"
CURRENT_LINK="${SITE_ROOT}/current"
PREVIOUS_LINK="${SITE_ROOT}/previous"
SERVICE_FILE="/etc/systemd/system/rtsp_probe@${SITE_CODE}.service"
SOURCE_SERVICE_TEMPLATE="${APP_SOURCE_ROOT}/deploy/rtsp_probe@.service"

if [[ ! -d "${APP_SOURCE_ROOT}" ]]; then
    echo "[install] jetson source directory not found: ${APP_SOURCE_ROOT}" >&2
    exit 1
fi

if [[ ! -f "${CONFIG_SOURCE}" ]]; then
    echo "[install] rendered config not found: ${CONFIG_SOURCE}" >&2
    exit 1
fi

if [[ -z "${RELEASE_VERSION}" && -f "${MANIFEST_SOURCE}" ]]; then
    RELEASE_VERSION="$(grep -o '"release_version"[[:space:]]*:[[:space:]]*"[^"]*"' "${MANIFEST_SOURCE}" | head -n1 | sed -E 's/.*"release_version"[[:space:]]*:[[:space:]]*"([^"]*)"/\1/')"
fi

if [[ -z "${RELEASE_VERSION}" ]]; then
    RELEASE_VERSION="$(date +%Y%m%d_%H%M%S)"
fi

TARGET_RELEASE_ROOT="${RELEASES_ROOT}/${RELEASE_VERSION}"

if [[ ! -f "${SOURCE_SERVICE_TEMPLATE}" ]]; then
    echo "[install] service template not found: ${SOURCE_SERVICE_TEMPLATE}" >&2
    exit 1
fi

CURRENT_TARGET=""
if [[ -L "${CURRENT_LINK}" ]]; then
    CURRENT_TARGET="$(readlink -f "${CURRENT_LINK}")"
fi

mkdir -p "${TARGET_RELEASE_ROOT}"
mkdir -p "${TARGET_RELEASE_ROOT}/jetson_edge_disnet_cpp"
cp -a "${APP_SOURCE_ROOT}/." "${TARGET_RELEASE_ROOT}/jetson_edge_disnet_cpp/"
mkdir -p "${TARGET_RELEASE_ROOT}/config"
cp "${CONFIG_SOURCE}" "${TARGET_RELEASE_ROOT}/config/device.ini"
if [[ -f "${MANIFEST_SOURCE}" ]]; then
    cp "${MANIFEST_SOURCE}" "${TARGET_RELEASE_ROOT}/site-manifest.json"
fi
chmod +x "${TARGET_RELEASE_ROOT}/jetson_edge_disnet_cpp/scripts/run_rtsp_probe.sh"

if [[ -n "${CURRENT_TARGET}" && "${CURRENT_TARGET}" != "${TARGET_RELEASE_ROOT}" ]]; then
    ln -sfn "${CURRENT_TARGET}" "${PREVIOUS_LINK}"
fi

ln -sfn "${TARGET_RELEASE_ROOT}" "${CURRENT_LINK}"
cp "${CURRENT_LINK}/jetson_edge_disnet_cpp/deploy/rtsp_probe@.service" "${SERVICE_FILE}"
systemctl daemon-reload
systemctl enable "rtsp_probe@${SITE_CODE}.service"
systemctl restart "rtsp_probe@${SITE_CODE}.service"
