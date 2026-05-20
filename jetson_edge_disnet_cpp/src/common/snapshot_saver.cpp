#include "common/snapshot_saver.hpp"
#include "common/logger.hpp"

#include <chrono>
#include <ctime>
#include <filesystem>
#include <iomanip>
#include <sstream>

SnapshotSaver::SnapshotSaver(std::string output_dir)
    : output_dir_(std::move(output_dir)) {
}

std::string SnapshotSaver::save(const cv::Mat& frame, const std::string& aibox_id, const std::string& cam_id) const {
    if (frame.empty()) {
        Logger::instance().warn("[snapshot] skip save because frame is empty");
        return "";
    }

    namespace fs = std::filesystem;
    std::error_code ec;
    fs::create_directories(output_dir_, ec);
    if (ec) {
        Logger::instance().error("[snapshot] failed to create directory: " + output_dir_);
        return "";
    }

    using namespace std::chrono;
    auto now = system_clock::now() + hours(8);
    std::time_t tt = system_clock::to_time_t(now);
    std::tm tm = *std::gmtime(&tt);

    std::ostringstream name;
    name << aibox_id << "_" << cam_id << "_"
         << std::put_time(&tm, "%Y%m%d_%H%M%S") << ".jpg";

    fs::path file_path = fs::path(output_dir_) / name.str();
    if (!cv::imwrite(file_path.string(), frame)) {
        Logger::instance().error("[snapshot] failed to save image: " + file_path.string());
        return "";
    }

    Logger::instance().info("[snapshot] saved: " + file_path.string());
    return file_path.string();
}
