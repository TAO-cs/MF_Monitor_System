#pragma once

#include <opencv2/opencv.hpp>

#include <deque>
#include <vector>

class FrameBuffer {
public:
    FrameBuffer(size_t window_size, size_t stride);

    void push(const cv::Mat& frame);
    bool ready() const;
    bool shouldInfer() const;
    std::vector<cv::Mat> getWindow() const;
    void markInferConsumed();
    size_t size() const;

private:
    std::deque<cv::Mat> frames_;
    size_t window_size_;
    size_t stride_;
    size_t frames_since_last_infer_;
    bool first_infer_ready_;
};
