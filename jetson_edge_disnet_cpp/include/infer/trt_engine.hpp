#pragma once

#include <NvInfer.h>
#include <cuda_runtime_api.h>

#include <string>
#include <vector>

class TrtEngine {
public:
    explicit TrtEngine(const std::string& engine_path);
    ~TrtEngine();

    bool initialize();
    bool infer(const std::vector<float>& input, std::vector<float>& output);

    int getInputSize() const;
    int getOutputSize() const;

private:
    std::string engine_path_;

    int input_size_;
    int output_size_;

    std::string input_tensor_name_;
    std::string output_tensor_name_;

    nvinfer1::IRuntime* runtime_;
    nvinfer1::ICudaEngine* engine_;
    nvinfer1::IExecutionContext* context_;

    void* input_device_;
    void* output_device_;
    cudaStream_t stream_;
};
