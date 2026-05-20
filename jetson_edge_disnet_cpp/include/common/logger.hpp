#pragma once

#include <fstream>
#include <mutex>
#include <string>

class Logger {
public:
    static Logger& instance();

    bool initialize(const std::string& output_dir);
    void info(const std::string& message);
    void warn(const std::string& message);
    void error(const std::string& message);

    std::string logPath() const;

private:
    Logger() = default;

    void write(const std::string& level, const std::string& message, bool to_stderr);
    std::string buildLogFileName() const;
    std::string timestampNow() const;

    mutable std::mutex mutex_;
    std::ofstream stream_;
    std::string log_path_;
    bool initialized_{false};
};
