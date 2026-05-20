#pragma once

#include <string>

struct EvidenceUploadConfig {
    bool enabled{false};
    std::string url;
    std::string api_key;
    int timeout_sec{15};
};

class EvidenceUploader {
public:
    explicit EvidenceUploader(EvidenceUploadConfig config);

    bool enabled() const;
    std::string upload(const std::string& local_path, const std::string& aibox_id, const std::string& cam_id) const;

private:
    EvidenceUploadConfig config_;
};
