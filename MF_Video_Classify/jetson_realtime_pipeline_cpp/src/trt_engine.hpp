#pragma once

#include <NvInfer.h>
#include <cuda_runtime_api.h>

#include <algorithm>
#include <chrono>
#include <fstream>
#include <iostream>
#include <memory>
#include <numeric>
#include <string>
#include <vector>

namespace trtapp {

class TrtLogger final : public nvinfer1::ILogger {
public:
    void log(Severity severity, const char* msg) noexcept override {
        if (severity <= Severity::kWARNING) {
            std::cerr << "[tensorrt] " << msg << "\n";
        }
    }
};

template <typename T>
struct TrtDestroy {
    void operator()(T* ptr) const {
        if (ptr) {
            delete ptr;
        }
    }
};

inline int64_t volume_of(const nvinfer1::Dims& dims) {
    int64_t volume = 1;
    for (int i = 0; i < dims.nbDims; ++i) {
        if (dims.d[i] < 0) {
            return -1;
        }
        volume *= dims.d[i];
    }
    return volume;
}

class TrtEngine {
public:
    bool load(const std::string& engine_path, int num_frames, int input_h, int input_w) {
        num_frames_ = num_frames;
        input_h_ = input_h;
        input_w_ = input_w;

        std::ifstream ifs(engine_path, std::ios::binary);
        if (!ifs) {
            std::cerr << "[trt] failed to open engine: " << engine_path << "\n";
            return false;
        }

        ifs.seekg(0, std::ios::end);
        const std::streamsize size = ifs.tellg();
        ifs.seekg(0, std::ios::beg);
        std::vector<char> engine_data(static_cast<size_t>(size));
        if (!ifs.read(engine_data.data(), size)) {
            std::cerr << "[trt] failed to read engine bytes\n";
            return false;
        }

        runtime_.reset(nvinfer1::createInferRuntime(logger_));
        if (!runtime_) {
            std::cerr << "[trt] createInferRuntime failed\n";
            return false;
        }

        engine_.reset(runtime_->deserializeCudaEngine(engine_data.data(), engine_data.size()));
        if (!engine_) {
            std::cerr << "[trt] deserializeCudaEngine failed\n";
            return false;
        }

        context_.reset(engine_->createExecutionContext());
        if (!context_) {
            std::cerr << "[trt] createExecutionContext failed\n";
            return false;
        }

        if (cudaStreamCreate(&stream_) != cudaSuccess) {
            std::cerr << "[trt] cudaStreamCreate failed\n";
            return false;
        }

        if (!resolve_io()) {
            return false;
        }

        if (!configure_shapes()) {
            return false;
        }

        if (!allocate_buffers()) {
            return false;
        }

        std::cout << "[trt] engine loaded. input=" << input_name_
                  << " output=" << output_name_
                  << " output_size=" << output_size_ << "\n";
        return true;
    }

    ~TrtEngine() {
        if (input_device_) {
            cudaFree(input_device_);
        }
        if (output_device_) {
            cudaFree(output_device_);
        }
        if (stream_) {
            cudaStreamDestroy(stream_);
        }
    }

    bool infer(const std::vector<float>& input, std::vector<float>& output, double& infer_ms) {
        if (input.size() != input_size_) {
            std::cerr << "[trt] input size mismatch. expected=" << input_size_
                      << " actual=" << input.size() << "\n";
            return false;
        }

        auto start = std::chrono::steady_clock::now();

        if (cudaMemcpyAsync(
                input_device_,
                input.data(),
                input_bytes_,
                cudaMemcpyHostToDevice,
                stream_) != cudaSuccess) {
            std::cerr << "[trt] cudaMemcpyAsync H2D failed\n";
            return false;
        }

#if NV_TENSORRT_MAJOR >= 10
        if (!context_->setTensorAddress(input_name_.c_str(), input_device_)) {
            std::cerr << "[trt] setTensorAddress for input failed\n";
            return false;
        }
        if (!context_->setTensorAddress(output_name_.c_str(), output_device_)) {
            std::cerr << "[trt] setTensorAddress for output failed\n";
            return false;
        }
        if (!context_->enqueueV3(stream_)) {
            std::cerr << "[trt] enqueueV3 failed\n";
            return false;
        }
#else
        std::vector<void*> bindings(static_cast<size_t>(engine_->getNbBindings()), nullptr);
        bindings[static_cast<size_t>(input_index_)] = input_device_;
        bindings[static_cast<size_t>(output_index_)] = output_device_;
        if (!context_->enqueueV2(bindings.data(), stream_, nullptr)) {
            std::cerr << "[trt] enqueueV2 failed\n";
            return false;
        }
#endif

        if (cudaMemcpyAsync(
                host_output_.data(),
                output_device_,
                output_bytes_,
                cudaMemcpyDeviceToHost,
                stream_) != cudaSuccess) {
            std::cerr << "[trt] cudaMemcpyAsync D2H failed\n";
            return false;
        }

        if (cudaStreamSynchronize(stream_) != cudaSuccess) {
            std::cerr << "[trt] cudaStreamSynchronize failed\n";
            return false;
        }

        auto end = std::chrono::steady_clock::now();
        infer_ms = std::chrono::duration<double, std::milli>(end - start).count();
        output = host_output_;
        return true;
    }

    int output_size() const {
        return output_size_;
    }

private:
    bool resolve_io() {
#if NV_TENSORRT_MAJOR >= 10
        const int nb = engine_->getNbIOTensors();
        for (int i = 0; i < nb; ++i) {
            const char* name = engine_->getIOTensorName(i);
            if (engine_->getTensorIOMode(name) == nvinfer1::TensorIOMode::kINPUT) {
                input_name_ = name;
            } else {
                output_name_ = name;
            }
        }
#else
        const int nb = engine_->getNbBindings();
        for (int i = 0; i < nb; ++i) {
            const char* name = engine_->getBindingName(i);
            if (engine_->bindingIsInput(i)) {
                input_index_ = i;
                input_name_ = name;
            } else {
                output_index_ = i;
                output_name_ = name;
            }
        }
#endif

        if (input_name_.empty() || output_name_.empty()) {
            std::cerr << "[trt] failed to resolve IO tensor names\n";
            return false;
        }
        return true;
    }

    bool configure_shapes() {
        nvinfer1::Dims input_dims{};
        input_dims.nbDims = 5;
        input_dims.d[0] = 1;
        input_dims.d[1] = num_frames_;
        input_dims.d[2] = 3;
        input_dims.d[3] = input_h_;
        input_dims.d[4] = input_w_;

#if NV_TENSORRT_MAJOR >= 10
        if (!context_->setInputShape(input_name_.c_str(), input_dims)) {
            std::cerr << "[trt] setInputShape failed\n";
            return false;
        }
        nvinfer1::Dims output_dims = context_->getTensorShape(output_name_.c_str());
#else
        if (!context_->setBindingDimensions(input_index_, input_dims)) {
            std::cerr << "[trt] setBindingDimensions failed\n";
            return false;
        }
        nvinfer1::Dims output_dims = context_->getBindingDimensions(output_index_);
#endif

        const int64_t input_volume = volume_of(input_dims);
        const int64_t output_volume = volume_of(output_dims);
        if (input_volume <= 0 || output_volume <= 0) {
            std::cerr << "[trt] invalid input/output dimensions after shape configuration\n";
            return false;
        }

        input_size_ = static_cast<size_t>(input_volume);
        input_bytes_ = input_size_ * sizeof(float);
        output_size_ = static_cast<int>(output_volume);
        output_bytes_ = static_cast<size_t>(output_size_) * sizeof(float);
        host_output_.assign(static_cast<size_t>(output_size_), 0.0f);
        return true;
    }

    bool allocate_buffers() {
        if (cudaMalloc(&input_device_, input_bytes_) != cudaSuccess) {
            std::cerr << "[trt] cudaMalloc input buffer failed\n";
            return false;
        }
        if (cudaMalloc(&output_device_, output_bytes_) != cudaSuccess) {
            std::cerr << "[trt] cudaMalloc output buffer failed\n";
            return false;
        }
        return true;
    }

    TrtLogger logger_;
    std::unique_ptr<nvinfer1::IRuntime, TrtDestroy<nvinfer1::IRuntime>> runtime_;
    std::unique_ptr<nvinfer1::ICudaEngine, TrtDestroy<nvinfer1::ICudaEngine>> engine_;
    std::unique_ptr<nvinfer1::IExecutionContext, TrtDestroy<nvinfer1::IExecutionContext>> context_;

    std::string input_name_;
    std::string output_name_;
    int input_index_{-1};
    int output_index_{-1};

    int num_frames_{8};
    int input_h_{240};
    int input_w_{240};

    size_t input_size_{0};
    size_t input_bytes_{0};
    int output_size_{0};
    size_t output_bytes_{0};

    void* input_device_{nullptr};
    void* output_device_{nullptr};
    cudaStream_t stream_{};
    std::vector<float> host_output_;
};

}  // namespace trtapp
