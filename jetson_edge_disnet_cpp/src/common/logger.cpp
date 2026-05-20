#include "common/logger.hpp"

#include <chrono>
#include <ctime>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <sstream>

Logger& Logger::instance() {
    static Logger logger;
    return logger;
}

bool Logger::initialize(const std::string& output_dir) {
    std::lock_guard<std::mutex> lock(mutex_);

    namespace fs = std::filesystem;
    std::error_code ec;
    fs::create_directories(output_dir, ec);
    if (ec) {
        std::cerr << "[ERROR] failed to create log directory: " << output_dir << std::endl;
        return false;
    }

    log_path_ = (fs::path(output_dir) / buildLogFileName()).string();
    stream_.open(log_path_, std::ios::out | std::ios::app);
    if (!stream_.is_open()) {
        std::cerr << "[ERROR] failed to open log file: " << log_path_ << std::endl;
        return false;
    }

    initialized_ = true;
    return true;
}

void Logger::info(const std::string& message) {
    write("INFO", message, false);
}

void Logger::warn(const std::string& message) {
    write("WARN", message, false);
}

void Logger::error(const std::string& message) {
    write("ERROR", message, true);
}

std::string Logger::logPath() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return log_path_;
}

void Logger::write(const std::string& level, const std::string& message, bool to_stderr) {
    std::lock_guard<std::mutex> lock(mutex_);

    std::ostringstream oss;
    oss << "[" << timestampNow() << "] "
        << "[" << level << "] "
        << message;

    const std::string line = oss.str();
    if (to_stderr) {
        std::cerr << line << std::endl;
    } else {
        std::cout << line << std::endl;
    }

    if (initialized_ && stream_.is_open()) {
        stream_ << line << std::endl;
        stream_.flush();
    }
}

std::string Logger::buildLogFileName() const {
    using namespace std::chrono;

    const auto now = system_clock::now();
    const std::time_t tt = system_clock::to_time_t(now);
    const std::tm tm = *std::localtime(&tt);

    std::ostringstream oss;
    oss << "rtsp_probe_" << std::put_time(&tm, "%Y%m%d_%H%M%S") << ".log";
    return oss.str();
}

std::string Logger::timestampNow() const {
    using namespace std::chrono;

    const auto now = system_clock::now();
    const std::time_t tt = system_clock::to_time_t(now);
    const std::tm tm = *std::localtime(&tt);

    std::ostringstream oss;
    oss << std::put_time(&tm, "%Y-%m-%d %H:%M:%S");
    return oss.str();
}
