#include "common/evidence_uploader.hpp"

#include "common/logger.hpp"

#include <curl/curl.h>

#include <cctype>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

namespace {

size_t writeCallback(void* contents, size_t size, size_t nmemb, void* userp) {
    const size_t total = size * nmemb;
    auto* buffer = static_cast<std::string*>(userp);
    if (!buffer || !contents) {
        return 0;
    }

    buffer->append(static_cast<const char*>(contents), total);
    return total;
}

std::string readFileBytes(const std::string& path, std::vector<char>& out) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs) {
        return "failed to open file";
    }

    out.assign(std::istreambuf_iterator<char>(ifs), std::istreambuf_iterator<char>());
    if (out.empty()) {
        return "file is empty";
    }
    return {};
}

std::string extractJsonString(const std::string& json, const std::string& key) {
    const std::string token = "\"" + key + "\"";
    const size_t key_pos = json.find(token);
    if (key_pos == std::string::npos) {
        return {};
    }

    size_t colon_pos = json.find(':', key_pos + token.size());
    if (colon_pos == std::string::npos) {
        return {};
    }

    size_t value_pos = colon_pos + 1;
    while (value_pos < json.size() && std::isspace(static_cast<unsigned char>(json[value_pos]))) {
        ++value_pos;
    }

    if (value_pos >= json.size() || json[value_pos] != '"') {
        return {};
    }
    ++value_pos;

    std::string result;
    bool escape = false;
    for (size_t i = value_pos; i < json.size(); ++i) {
        const char ch = json[i];
        if (escape) {
            result.push_back(ch);
            escape = false;
            continue;
        }
        if (ch == '\\') {
            escape = true;
            continue;
        }
        if (ch == '"') {
            return result;
        }
        result.push_back(ch);
    }

    return {};
}

std::string buildUploadUrl(CURL* curl, const std::string& base_url, const std::string& aibox_id, const std::string& cam_id) {
    char* encoded_aibox = curl_easy_escape(curl, aibox_id.c_str(), static_cast<int>(aibox_id.size()));
    char* encoded_cam = curl_easy_escape(curl, cam_id.c_str(), static_cast<int>(cam_id.size()));
    if (!encoded_aibox || !encoded_cam) {
        if (encoded_aibox) {
            curl_free(encoded_aibox);
        }
        if (encoded_cam) {
            curl_free(encoded_cam);
        }
        return {};
    }

    std::ostringstream oss;
    oss << base_url
        << (base_url.find('?') == std::string::npos ? '?' : '&')
        << "aibox_id=" << encoded_aibox
        << "&cam_id=" << encoded_cam;

    curl_free(encoded_aibox);
    curl_free(encoded_cam);
    return oss.str();
}

}  // namespace

EvidenceUploader::EvidenceUploader(EvidenceUploadConfig config)
    : config_(std::move(config)) {
}

bool EvidenceUploader::enabled() const {
    return config_.enabled && !config_.url.empty() && !config_.api_key.empty();
}

std::string EvidenceUploader::upload(const std::string& local_path, const std::string& aibox_id, const std::string& cam_id) const {
    if (!enabled()) {
        return {};
    }

    std::vector<char> payload;
    const std::string file_error = readFileBytes(local_path, payload);
    if (!file_error.empty()) {
        Logger::instance().warn("[evidence] upload skipped: " + file_error + " | file=" + local_path);
        return {};
    }

    CURL* curl = curl_easy_init();
    if (!curl) {
        Logger::instance().warn("[evidence] failed to initialize curl");
        return {};
    }

    const std::string upload_url = buildUploadUrl(curl, config_.url, aibox_id, cam_id);
    if (upload_url.empty()) {
        Logger::instance().warn("[evidence] failed to build upload url");
        curl_easy_cleanup(curl);
        return {};
    }

    const std::string file_name = std::filesystem::path(local_path).filename().string();
    std::string response_body;
    struct curl_slist* headers = nullptr;
    headers = curl_slist_append(headers, ("Authorization: Bearer " + config_.api_key).c_str());
    headers = curl_slist_append(headers, ("X-File-Name: " + file_name).c_str());
    headers = curl_slist_append(headers, "Content-Type: image/jpeg");

    curl_easy_setopt(curl, CURLOPT_URL, upload_url.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload.data());
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(payload.size()));
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, static_cast<long>(config_.timeout_sec));
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, static_cast<long>(config_.timeout_sec));
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, &writeCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response_body);

    const CURLcode rc = curl_easy_perform(curl);
    long http_status = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_status);

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    if (rc != CURLE_OK) {
        Logger::instance().warn("[evidence] upload failed: " + std::string(curl_easy_strerror(rc)));
        return {};
    }

    if (http_status < 200 || http_status >= 300) {
        Logger::instance().warn(
            "[evidence] upload failed with http status " + std::to_string(http_status) + " | body=" + response_body
        );
        return {};
    }

    std::string image_url = extractJsonString(response_body, "image_url");
    if (image_url.empty()) {
        image_url = extractJsonString(response_body, "image_path");
    }
    if (image_url.empty()) {
        Logger::instance().warn("[evidence] upload response missing image_url/image_path");
        return {};
    }

    Logger::instance().info("[evidence] uploaded: " + image_url);
    return image_url;
}
