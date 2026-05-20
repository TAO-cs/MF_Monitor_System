# Jetson Realtime Pipeline C++

This folder contains a Jetson-oriented C++ realtime pipeline for:

1. Pulling RTSP video
2. Building an 8-frame temporal window
3. Running TensorRT inference with `EdgeDisNet_fp16.engine`
4. Publishing `device_status` and `classification` to your MQTT platform

## Files

- `src/main.cpp`
  Final realtime pipeline entry point
- `src/trt_engine.hpp`
  TensorRT engine loader and inference wrapper
- `src/mqtt_reporter.hpp`
  MQTT publisher based on `libmosquitto`
- `CMakeLists.txt`
  Jetson build file

## Dependencies on Jetson

Install these packages if they are missing:

```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake libopencv-dev libmosquitto-dev
```

TensorRT and CUDA are usually already present with JetPack.

## Build

```bash
cd /mudflow_project
mkdir -p build_realtime_cpp
cd build_realtime_cpp
cmake ../MF_Video_Classify/jetson_realtime_pipeline_cpp
make -j$(nproc)
```

The executable will be:

```bash
./jetson_realtime_pipeline
```

## Run

Example:

```bash
./jetson_realtime_pipeline \
  --source="rtsp://127.0.0.1:8554/mf001" \
  --engine="/mudflow_project/model_onnx/EdgeDisNet_fp16.engine" \
  --aibox_id="MF001" \
  --cam_id="CAM001" \
  --mqtt=1 \
  --mqtt_host="192.168.1.100" \
  --mqtt_port=1883 \
  --show=0
```

## Platform topics

This program publishes:

- `disaster_monitoring/{aibox_id}/device_status`
- `disaster_monitoring/{aibox_id}/classification`

## Recommended first run

Run in two stages:

1. Verify the video path and inference only:

```bash
./jetson_realtime_pipeline \
  --source="rtsp://127.0.0.1:8554/mf001" \
  --engine="/mudflow_project/model_onnx/EdgeDisNet_fp16.engine" \
  --mqtt=0 \
  --show=1
```

2. Then enable MQTT:

```bash
./jetson_realtime_pipeline \
  --source="rtsp://127.0.0.1:8554/mf001" \
  --engine="/mudflow_project/model_onnx/EdgeDisNet_fp16.engine" \
  --mqtt=1 \
  --mqtt_host="127.0.0.1" \
  --mqtt_port=1883 \
  --show=0
```

## Notes

- This pipeline assumes the model output classes are:
  - `flood`
  - `mudslide`
- Because the model has no `normal` class, the program uses:
  - confidence threshold
  - stable window voting
  - publish cooldown
- Debug frames are saved to:

```bash
/mudflow_project/debug_frames
```

You can change that with `--save_debug_dir`.
