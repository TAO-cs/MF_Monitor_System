#include "preprocess/frame_buffer.hpp"

FrameBuffer::FrameBuffer(size_t window_size, size_t stride)
    : window_size_(window_size),
      stride_(stride),
      frames_since_last_infer_(0),
      first_infer_ready_(false) {
}

void FrameBuffer::push(const cv::Mat& frame) {
    if (frame.empty()) {
        return;
    }

    frames_.push_back(frame.clone());

    while (frames_.size() > window_size_) {
        frames_.pop_front();
    }

    if (frames_.size() == window_size_) {
        if (!first_infer_ready_) {
            first_infer_ready_ = true;
            frames_since_last_infer_ = stride_;
        } else {
            frames_since_last_infer_++;
        }
    }
}

bool FrameBuffer::ready() const {
    return frames_.size() == window_size_;
}

bool FrameBuffer::shouldInfer() const {
    if (!ready()) {
        return false;
    }

    return frames_since_last_infer_ >= stride_;
}

std::vector<cv::Mat> FrameBuffer::getWindow() const {
    return std::vector<cv::Mat>(frames_.begin(), frames_.end());
}

void FrameBuffer::markInferConsumed() {
    frames_since_last_infer_ = 0;
}

size_t FrameBuffer::size() const {
    return frames_.size();
}
