# Jetson EdgeDisNet C++ Service

## Overview
This subproject is the deployable Jetson edge inference service for a single site:

- one camera
- one Jetson
- one `aibox_id / cam_id`
- RTSP input from local `mediamtx`
- TensorRT inference from local engine
- MQTT reporting to the HA platform

The current implementation is service-ready and keeps the following engineering capabilities:

- config-driven startup
- RTSP auto reconnect
- MQTT auto reconnect
- event snapshot saving
- `image_path` reporting
- runtime log files
- `systemd` service deployment
- Jetson-local TensorRT engine support
- self-contained per-site deployment bundle generation

## Directory Layout

```text
jetson_edge_disnet_cpp/
  configs/
    device.ini
  deploy/
    rtsp_probe.service
  docs/
    README.md
  include/
    common/
    infer/
    mqtt/
    preprocess/
    stream/
  runtime/
    logs/
    snapshots/
  scripts/
    run_rtsp_probe.sh
  src/
    common/
    infer/
    preprocess/
    stream/
    main.cpp
  CMakeLists.txt
```

## Build

This service is not a generic desktop C++ demo. It targets Jetson Linux and expects:

- Ubuntu on NVIDIA Jetson, not native Windows
- `cmake`, `make`, and a C++17 compiler
- OpenCV development files
- CUDA and TensorRT from JetPack
- `libmosquitto-dev`
- `libcurl4-openssl-dev`

Typical dependency install on Jetson:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  cmake \
  pkg-config \
  libopencv-dev \
  libmosquitto-dev \
  libcurl4-openssl-dev
```

Notes:

- TensorRT and CUDA are usually provided by JetPack and must match the device architecture.
- The default `CMakeLists.txt` searches Linux aarch64 paths such as `/usr/lib/aarch64-linux-gnu`, so building on Windows directly will fail unless you switch to WSL/Linux and provide compatible dependencies.
- You also need a valid TensorRT engine file and a reachable RTSP stream at runtime.

```bash
cd ~/mudflow_project/jetson_edge_disnet_cpp
mkdir -p build
cd build
cmake ..
make -j$(nproc)
```

If `cmake` itself is missing, install it first. If configuration fails, the updated `CMakeLists.txt` will now stop with a direct message for the missing dependency.

## Run

Manual run:

```bash
~/mudflow_project/jetson_edge_disnet_cpp/build/rtsp_probe /home/nvidia/mudflow_project/jetson_edge_disnet_cpp/configs/device.ini
```

Service run:

```bash
sudo systemctl start rtsp_probe.service
systemctl status rtsp_probe.service
journalctl -u rtsp_probe.service -n 50 --no-pager
```

## Runtime Outputs

Generated outputs are intentionally kept outside source directories:

- logs: `runtime/logs/`
- snapshots: `runtime/snapshots/`

These are runtime artifacts and should not be treated as source files.

## Key Config

Main config file:

```text
configs/device.ini
```

Important keys:

- `aibox_id`
- `cam_id`
- `rtsp_url`
- `engine_path`
- `mqtt_host`
- `mqtt_port`
- `confidence_threshold`
- `stable_window`
- `cooldown_sec`
- `status_interval_sec`
- `snapshot_dir`
- `log_dir`
- `rtsp_reconnect_sec`
- `mqtt_reconnect_sec`

## Deployment Files

- startup script: `scripts/run_rtsp_probe.sh`
- systemd service: `deploy/rtsp_probe.service`

## Inventory Bundle Flow

For week-1 batch landing, the repo now supports site bundle rendering from the shared inventory source:

- inventory source: `../deploy/inventory/devices.csv`
- config template: `configs/templates/device.ini.template`
- rendered output: `../artifacts/jetson-sites/<SITE_CODE>/config/device.ini`
- site manifest: `../artifacts/jetson-sites/<SITE_CODE>/site-manifest.json`
- bundled Jetson payload: `../artifacts/jetson-sites/<SITE_CODE>/jetson_edge_disnet_cpp/`
- packaged output: `../artifacts/jetson-sites/<SITE_CODE>.zip`
- rollout plan: `../artifacts/jetson-sites/rollout-plan.csv`

Render all site configs from Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\render_jetson_site_bundle.ps1 -ReleaseVersion 2026.05.21-rc1 -EvidenceUploadApiKey <EVIDENCE_UPLOAD_API_KEY>
```

Package all site bundles:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package_jetson_bundles.ps1
```

Generate the batch rollout rehearsal plan:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\render_jetson_rollout_plan.ps1 -BundleRoot .\artifacts\jetson-sites -ReleaseVersion 2026.05.21-rc1
```

Each rendered site bundle is self-contained: it already includes the Jetson source tree, install script, service template, rendered config, and site manifest.

Install one site bundle on Jetson directly from the extracted site package root:

```bash
sudo bash jetson_edge_disnet_cpp/deploy/install_site.sh SITE01 /path/to/site-bundle-root 2026.05.21-rc1
```

Enable and start the per-site service:

```bash
sudo systemctl enable rtsp_probe@SITE01.service
sudo systemctl start rtsp_probe@SITE01.service
```

Rollback one site to the previous release:

```bash
sudo bash /path/to/site-bundle-root/deploy/rollback_site_update.sh SITE01
```

Re-running `install_site.sh` for the same `SITE_CODE` is supported. The installer now writes versioned releases under `/opt/mf-monitor/<SITE_CODE>/releases`, switches the `current` symlink, and preserves the last release in `previous` for rollback.

## Document Entry

Recommended reading order:

1. project deployment steps: [启动说明文件.txt](../启动说明文件.txt)
2. implementation roadmap: [Jetson部署实施规划.md](../Jetson部署实施规划.md)
3. final acceptance checklist: [Jetson最终验收与交付清单.md](../Jetson最终验收与交付清单.md)

## Scope Note

This folder is the Jetson-side deployable service only.
It does not replace or restructure the backend / frontend / HA platform source tree in the repository root.
