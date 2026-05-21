#!/usr/bin/env bash
set -euo pipefail

SITE_CODE="${1:?site code required}"
SITE_ROOT="/opt/mf-monitor/${SITE_CODE}"
CURRENT_LINK="${SITE_ROOT}/current"
PREVIOUS_LINK="${SITE_ROOT}/previous"
SERVICE_FILE="/etc/systemd/system/rtsp_probe@${SITE_CODE}.service"

if [[ ! -L "${PREVIOUS_LINK}" ]]; then
    echo "[rollback] previous release link not found: ${PREVIOUS_LINK}" >&2
    exit 1
fi

ROLLBACK_TARGET="$(readlink -f "${PREVIOUS_LINK}")"
if [[ -z "${ROLLBACK_TARGET}" || ! -d "${ROLLBACK_TARGET}" ]]; then
    echo "[rollback] rollback target not found: ${PREVIOUS_LINK}" >&2
    exit 1
fi

CURRENT_TARGET=""
if [[ -L "${CURRENT_LINK}" ]]; then
    CURRENT_TARGET="$(readlink -f "${CURRENT_LINK}")"
fi

ln -sfn "${ROLLBACK_TARGET}" "${CURRENT_LINK}"

if [[ -n "${CURRENT_TARGET}" && "${CURRENT_TARGET}" != "${ROLLBACK_TARGET}" ]]; then
    ln -sfn "${CURRENT_TARGET}" "${PREVIOUS_LINK}"
fi

cp "${CURRENT_LINK}/jetson_edge_disnet_cpp/deploy/rtsp_probe@.service" "${SERVICE_FILE}"
systemctl daemon-reload
systemctl restart "rtsp_probe@${SITE_CODE}.service"
