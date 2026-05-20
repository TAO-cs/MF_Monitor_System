#include "preprocess/preprocessor.hpp"

#include <stdexcept>

Preprocessor::Preprocessor(int input_width, int input_height)
    : input_width_(input_width), input_height_(input_height) {
}

std::vector<float> Preprocessor::process(const std::vector<cv::Mat>& frames) const {
    if (frames.empty()) {
        throw std::runtime_error("Preprocessor received empty frame list.");
    }

    const int num_frames = static_cast<int>(frames.size());
    const int channels = 3;
    const int hw = input_width_ * input_height_;

    std::vector<float> output(num_frames * channels * hw, 0.0f);

    const float mean[3] = {0.485f, 0.456f, 0.406f};
    const float stdv[3] = {0.229f, 0.224f, 0.225f};

    for (int t = 0; t < num_frames; ++t) {
        if (frames[t].empty()) {
            throw std::runtime_error("Preprocessor received empty frame.");
        }

        cv::Mat rgb;
        cv::cvtColor(frames[t], rgb, cv::COLOR_BGR2RGB);

        cv::Mat resized;
        cv::resize(rgb, resized, cv::Size(input_width_, input_height_), 0, 0, cv::INTER_CUBIC);

        cv::Mat float_img;
        resized.convertTo(float_img, CV_32FC3, 1.0 / 255.0);

        std::vector<cv::Mat> split_channels;
        cv::split(float_img, split_channels);

        for (int c = 0; c < channels; ++c) {
            for (int h = 0; h < input_height_; ++h) {
                for (int w = 0; w < input_width_; ++w) {
                    float value = split_channels[c].at<float>(h, w);
                    value = (value - mean[c]) / stdv[c];

                    int index = t * channels * hw
                              + c * hw
                              + h * input_width_
                              + w;

                    output[index] = value;
                }
            }
        }
    }

    return output;
}

int Preprocessor::inputWidth() const {
    return input_width_;
}

int Preprocessor::inputHeight() const {
    return input_height_;
}
