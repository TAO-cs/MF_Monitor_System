#pragma once

#include <opencv2/opencv.hpp>

#include <vector>

class Preprocessor {
public:
    Preprocessor(int input_width, int input_height);

    std::vector<float> process(const std::vector<cv::Mat>& frames) const;

    int inputWidth() const;
    int inputHeight() const;

private:
    int input_width_;
    int input_height_;
};
