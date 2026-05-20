#pragma once

#include <opencv2/opencv.hpp>
#include <string>

class RtspReader {
public:
    bool open(const std::string& source);
    bool read(cv::Mat& frame);
    bool reopen();
    void close();

    bool isOpened() const;
    cv::Size frameSize() const;

private:
    cv::VideoCapture cap_;
    std::string source_;
};
