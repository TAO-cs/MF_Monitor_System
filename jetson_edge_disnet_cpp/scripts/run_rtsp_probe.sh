#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BINARY_PATH="${PROJECT_ROOT}/build/rtsp_probe"
CONFIG_PATH="${PROJECT_ROOT}/configs/device.ini"
RUNTIME_DIR="${PROJECT_ROOT}/runtime"

mkdir -p "${RUNTIME_DIR}/logs"
mkdir -p "${RUNTIME_DIR}/snapshots"

if [[ ! -x "${BINARY_PATH}" ]]; then
    echo "[service] binary not found or not executable: ${BINARY_PATH}" >&2
    exit 1
fi

if [[ ! -f "${CONFIG_PATH}" ]]; then
    echo "[service] config file not found: ${CONFIG_PATH}" >&2
    exit 1
fi

cd "${PROJECT_ROOT}"
exec "${BINARY_PATH}" "${CONFIG_PATH}"
