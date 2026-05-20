#include "infer/trt_engine.hpp"

#include <fstream>
#include <iostream>
#include <vector>

namespace {

class TrtLogger : public nvinfer1::ILogger {
public:
    void log(Severity severity, const char* msg) noexcept override {
        if (severity <= Severity::kWARNING) {
            std::cout << "[TRT][LOG] " << msg << std::endl;
        }
    }
};

std::string dimsToString(const nvinfer1::Dims& dims) {
    std::string result;
    for (int i = 0; i < dims.nbDims; ++i) {
        result += std::to_string(dims.d[i]);
        if (i + 1 < dims.nbDims) {
            result += " x ";
        }
    }
    return result;
}

int dimsVolume(const nvinfer1::Dims& dims) {
    int volume = 1;
    for (int i = 0; i < dims.nbDims; ++i) {
        if (dims.d[i] < 0) {
            return -1;
        }
        volume *= dims.d[i];
    }
    return volume;
}

}  // namespace

TrtEngine::TrtEngine(const std::string& engine_path)
    : engine_path_(engine_path),
      input_size_(0),
      output_size_(0),
      runtime_(nullptr),
      engine_(nullptr),
      context_(nullptr),
      input_device_(nullptr),
      output_device_(nullptr),
      stream_(nullptr) {
}

TrtEngine::~TrtEngine() {
    if (input_device_ != nullptr) {
        cudaFree(input_device_);
        input_device_ = nullptr;
    }

    if (output_device_ != nullptr) {
        cudaFree(output_device_);
        output_device_ = nullptr;
    }

    if (stream_ != nullptr) {
        cudaStreamDestroy(stream_);
        stream_ = nullptr;
    }

    if (context_ != nullptr) {
        delete context_;
        context_ = nullptr;
    }

    if (engine_ != nullptr) {
        delete engine_;
        engine_ = nullptr;
    }

    if (runtime_ != nullptr) {
        delete runtime_;
        runtime_ = nullptr;
    }
}

bool TrtEngine::initialize() {
    std::ifstream file(engine_path_, std::ios::binary);
    if (!file) {
        std::cerr << "[TRT] Failed to open engine file: " << engine_path_ << std::endl;
        return false;
    }

    file.seekg(0, std::ios::end);
    std::streamsize size = file.tellg();
    file.seekg(0, std::ios::beg);

    if (size <= 0) {
        std::cerr << "[TRT] Engine file is empty: " << engine_path_ << std::endl;
        return false;
    }

    std::vector<char> engine_data(static_cast<size_t>(size));
    if (!file.read(engine_data.data(), size)) {
        std::cerr << "[TRT] Failed to read engine bytes." << std::endl;
        return false;
    }

    static TrtLogger logger;

    runtime_ = nvinfer1::createInferRuntime(logger);
    if (!runtime_) {
        std::cerr << "[TRT] Failed to create runtime." << std::endl;
        return false;
    }

    engine_ = runtime_->deserializeCudaEngine(engine_data.data(), engine_data.size());
    if (!engine_) {
        std::cerr << "[TRT] Failed to deserialize engine." << std::endl;
        return false;
    }

    context_ = engine_->createExecutionContext();
    if (!context_) {
        std::cerr << "[TRT] Failed to create execution context." << std::endl;
        return false;
    }

    std::cout << "[TRT] Engine loaded successfully: " << engine_path_ << std::endl;

    int num_tensors = engine_->getNbIOTensors();
    for (int i = 0; i < num_tensors; ++i) {
        const char* tensor_name = engine_->getIOTensorName(i);
        auto mode = engine_->getTensorIOMode(tensor_name);
        nvinfer1::Dims dims = engine_->getTensorShape(tensor_name);

        std::string mode_text = (mode == nvinfer1::TensorIOMode::kINPUT) ? "INPUT" : "OUTPUT";

        std::cout << "[TRT] " << mode_text
                  << " tensor: " << tensor_name
                  << " | shape: " << dimsToString(dims)
                  << std::endl;

        if (mode == nvinfer1::TensorIOMode::kINPUT) {
            input_tensor_name_ = tensor_name;
        } else {
            output_tensor_name_ = tensor_name;
        }
    }

    nvinfer1::Dims input_dims;
    input_dims.nbDims = 5;
    input_dims.d[0] = 1;
    input_dims.d[1] = 8;
    input_dims.d[2] = 3;
    input_dims.d[3] = 240;
    input_dims.d[4] = 240;

    if (!context_->setInputShape(input_tensor_name_.c_str(), input_dims)) {
        std::cerr << "[TRT] Failed to set input shape." << std::endl;
        return false;
    }

    nvinfer1::Dims resolved_input_dims = context_->getTensorShape(input_tensor_name_.c_str());
    nvinfer1::Dims resolved_output_dims = context_->getTensorShape(output_tensor_name_.c_str());

    input_size_ = dimsVolume(resolved_input_dims);
    output_size_ = dimsVolume(resolved_output_dims);

    std::cout << "[TRT] Resolved INPUT shape: " << dimsToString(resolved_input_dims) << std::endl;
    std::cout << "[TRT] Resolved OUTPUT shape: " << dimsToString(resolved_output_dims) << std::endl;

    if (input_size_ <= 0 || output_size_ <= 0) {
        std::cerr << "[TRT] Invalid input/output size." << std::endl;
        return false;
    }

    size_t input_bytes = static_cast<size_t>(input_size_) * sizeof(float);
    size_t output_bytes = static_cast<size_t>(output_size_) * sizeof(float);

    if (cudaMalloc(&input_device_, input_bytes) != cudaSuccess) {
        std::cerr << "[TRT] cudaMalloc failed for input buffer." << std::endl;
        return false;
    }

    if (cudaMalloc(&output_device_, output_bytes) != cudaSuccess) {
        std::cerr << "[TRT] cudaMalloc failed for output buffer." << std::endl;
        return false;
    }

    if (cudaStreamCreate(&stream_) != cudaSuccess) {
        std::cerr << "[TRT] cudaStreamCreate failed." << std::endl;
        return false;
    }

    return true;
}

bool TrtEngine::infer(const std::vector<float>& input, std::vector<float>& output) {
    if (input.size() != static_cast<size_t>(input_size_)) {
        std::cerr << "[TRT] Input size mismatch. Expected "
                  << input_size_ << ", got " << input.size() << std::endl;
        return false;
    }

    size_t input_bytes = static_cast<size_t>(input_size_) * sizeof(float);
    size_t output_bytes = static_cast<size_t>(output_size_) * sizeof(float);

    output.resize(static_cast<size_t>(output_size_));

    if (cudaMemcpyAsync(input_device_, input.data(), input_bytes, cudaMemcpyHostToDevice, stream_) != cudaSuccess) {
        std::cerr << "[TRT] cudaMemcpyAsync H2D failed." << std::endl;
        return false;
    }

    if (!context_->setTensorAddress(input_tensor_name_.c_str(), input_device_)) {
        std::cerr << "[TRT] Failed to bind input tensor address." << std::endl;
        return false;
    }

    if (!context_->setTensorAddress(output_tensor_name_.c_str(), output_device_)) {
        std::cerr << "[TRT] Failed to bind output tensor address." << std::endl;
        return false;
    }

    if (!context_->enqueueV3(stream_)) {
        std::cerr << "[TRT] enqueueV3 failed." << std::endl;
        return false;
    }

    if (cudaMemcpyAsync(output.data(), output_device_, output_bytes, cudaMemcpyDeviceToHost, stream_) != cudaSuccess) {
        std::cerr << "[TRT] cudaMemcpyAsync D2H failed." << std::endl;
        return false;
    }

    if (cudaStreamSynchronize(stream_) != cudaSuccess) {
        std::cerr << "[TRT] cudaStreamSynchronize failed." << std::endl;
        return false;
    }

    return true;
}

int TrtEngine::getInputSize() const {
    return input_size_;
}

int TrtEngine::getOutputSize() const {
    return output_size_;
}
