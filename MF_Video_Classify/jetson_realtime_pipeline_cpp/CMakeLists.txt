cmake_minimum_required(VERSION 3.18)
project(jetson_realtime_pipeline LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(OpenCV REQUIRED)
find_package(CUDAToolkit REQUIRED)

find_path(TENSORRT_INCLUDE_DIR NvInfer.h
  PATHS
    /usr/include/aarch64-linux-gnu
    /usr/include
    /usr/local/include
)

find_library(TENSORRT_LIBRARY nvinfer
  PATHS
    /usr/lib/aarch64-linux-gnu
    /usr/lib
    /usr/local/lib
)

find_library(TENSORRT_PLUGIN_LIBRARY nvinfer_plugin
  PATHS
    /usr/lib/aarch64-linux-gnu
    /usr/lib
    /usr/local/lib
)

find_library(MOSQUITTO_LIBRARY mosquitto
  PATHS
    /usr/lib/aarch64-linux-gnu
    /usr/lib
    /usr/local/lib
)

if(NOT TENSORRT_INCLUDE_DIR OR NOT TENSORRT_LIBRARY)
  message(FATAL_ERROR "TensorRT headers or libraries were not found.")
endif()

if(NOT MOSQUITTO_LIBRARY)
  message(FATAL_ERROR "libmosquitto was not found. Install libmosquitto-dev on Jetson.")
endif()

add_executable(jetson_realtime_pipeline
  src/main.cpp
)

target_include_directories(jetson_realtime_pipeline PRIVATE
  ${OpenCV_INCLUDE_DIRS}
  ${TENSORRT_INCLUDE_DIR}
  ${CUDAToolkit_INCLUDE_DIRS}
  ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(jetson_realtime_pipeline PRIVATE
  ${OpenCV_LIBS}
  CUDA::cudart
  ${TENSORRT_LIBRARY}
  ${TENSORRT_PLUGIN_LIBRARY}
  ${MOSQUITTO_LIBRARY}
)
