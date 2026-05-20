#include "stream/rtsp_reader.hpp"

bool RtspReader::open(const std::string& source) {
    source_ = source;
    close();

    if (cap_.open(source, cv::CAP_FFMPEG)) {
        return true;
    }

    return cap_.open(source, cv::CAP_ANY);
}

bool RtspReader::read(cv::Mat& frame) {
    if (!cap_.isOpened()) {
        return false;
    }

    if (!cap_.read(frame)) {
        return false;
    }

    return !frame.empty();
}

bool RtspReader::reopen() {
    if (source_.empty()) {
        return false;
    }

    return open(source_);
}

void RtspReader::close() {
    if (cap_.isOpened()) {
        cap_.release();
    }
}

bool RtspReader::isOpened() const {
    return cap_.isOpened();
}

cv::Size RtspReader::frameSize() const {
    int width = static_cast<int>(cap_.get(cv::CAP_PROP_FRAME_WIDTH));
    int height = static_cast<int>(cap_.get(cv::CAP_PROP_FRAME_HEIGHT));
    return cv::Size(width, height);
}
