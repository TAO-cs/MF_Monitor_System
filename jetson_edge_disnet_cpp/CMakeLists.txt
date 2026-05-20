cmake_minimum_required(VERSION 3.16)

project(rtsp_probe)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(OpenCV REQUIRED)

find_path(CUDART_INCLUDE_DIR cuda_runtime_api.h
    PATHS
    /usr/local/cuda-12.6/targets/aarch64-linux/include
    /usr/local/cuda/include
)

find_path(TENSORRT_INCLUDE_DIR NvInfer.h
    PATHS
    /usr/include/aarch64-linux-gnu
    /usr/include
)

find_library(TENSORRT_LIBRARY nvinfer
    PATHS
    /usr/lib/aarch64-linux-gnu
    /usr/lib
)

find_library(CUDART_LIBRARY cudart
    PATHS
    /usr/local/cuda-12.6/targets/aarch64-linux/lib
    /usr/local/cuda/lib64
)

find_library(MOSQUITTO_LIBRARY mosquitto
    PATHS
    /usr/lib/aarch64-linux-gnu
    /usr/lib
)

find_path(CURL_INCLUDE_DIR curl/curl.h
    PATHS
    /usr/include
    /usr/local/include
)

find_library(CURL_LIBRARY curl
    PATHS
    /usr/lib/aarch64-linux-gnu
    /usr/lib
    /usr/local/lib
)

if (NOT OpenCV_FOUND)
    message(FATAL_ERROR "OpenCV not found. Install OpenCV development files before building.")
endif()

if (NOT CUDART_INCLUDE_DIR)
    message(FATAL_ERROR
        "CUDA headers not found (missing cuda_runtime_api.h). "
        "This project is intended for Jetson/Linux with JetPack CUDA installed."
    )
endif()

if (NOT TENSORRT_INCLUDE_DIR)
    message(FATAL_ERROR
        "TensorRT headers not found (missing NvInfer.h). "
        "Install TensorRT development files from JetPack."
    )
endif()

if (NOT TENSORRT_LIBRARY)
    message(FATAL_ERROR
        "TensorRT library not found (missing nvinfer). "
        "Install TensorRT runtime/devel packages from JetPack."
    )
endif()

if (NOT CUDART_LIBRARY)
    message(FATAL_ERROR
        "CUDA runtime library not found (missing cudart). "
        "Install CUDA runtime/devel packages from JetPack."
    )
endif()

if (NOT MOSQUITTO_LIBRARY)
    message(FATAL_ERROR
        "libmosquitto not found. Install libmosquitto-dev before building."
    )
endif()

if (NOT CURL_INCLUDE_DIR OR NOT CURL_LIBRARY)
    message(FATAL_ERROR
        "libcurl not found. Install libcurl4-openssl-dev before building."
    )
endif()

include_directories(
    ${OpenCV_INCLUDE_DIRS}
    ${CUDART_INCLUDE_DIR}
    ${TENSORRT_INCLUDE_DIR}
    ${CURL_INCLUDE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

add_executable(rtsp_probe
    src/main.cpp
    src/common/config_loader.cpp
    src/common/evidence_uploader.cpp
    src/common/logger.cpp
    src/common/snapshot_saver.cpp
    src/stream/rtsp_reader.cpp
    src/preprocess/frame_buffer.cpp
    src/preprocess/postprocessor.cpp
    src/preprocess/preprocessor.cpp
    src/infer/trt_engine.cpp
)

target_link_libraries(rtsp_probe
    ${OpenCV_LIBS}
    ${TENSORRT_LIBRARY}
    ${CUDART_LIBRARY}
    ${MOSQUITTO_LIBRARY}
    ${CURL_LIBRARY}
)
