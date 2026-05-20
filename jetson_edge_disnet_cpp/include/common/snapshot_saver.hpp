#pragma once

#include <opencv2/opencv.hpp>

#include <string>

class SnapshotSaver {
public:
    explicit SnapshotSaver(std::string output_dir);

    std::string save(const cv::Mat& frame, const std::string& aibox_id, const std::string& cam_id) const;

private:
    std::string output_dir_;
};
