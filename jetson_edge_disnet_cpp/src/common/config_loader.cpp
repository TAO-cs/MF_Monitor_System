#include "common/config_loader.hpp"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <iostream>

namespace {

std::string trim(const std::string& input) {
    auto begin = input.begin();
    while (begin != input.end() && std::isspace(static_cast<unsigned char>(*begin))) {
        ++begin;
    }

    auto end = input.end();
    while (end != begin && std::isspace(static_cast<unsigned char>(*(end - 1)))) {
        --end;
    }

    return std::string(begin, end);
}

}  // namespace

bool ConfigLoader::load(const std::string& path) {
    std::ifstream file(path);
    if (!file) {
        std::cerr << "[config] failed to open file: " << path << std::endl;
        return false;
    }

    values_.clear();

    std::string line;
    while (std::getline(file, line)) {
        std::string cleaned = trim(line);
        if (cleaned.empty() || cleaned[0] == '#') {
            continue;
        }

        std::size_t pos = cleaned.find('=');
        if (pos == std::string::npos) {
            continue;
        }

        std::string key = trim(cleaned.substr(0, pos));
        std::string value = trim(cleaned.substr(pos + 1));
        if (!key.empty()) {
            values_[key] = value;
        }
    }

    return true;
}

std::string ConfigLoader::getString(const std::string& key, const std::string& default_value) const {
    auto it = values_.find(key);
    if (it == values_.end()) {
        return default_value;
    }
    return it->second;
}

int ConfigLoader::getInt(const std::string& key, int default_value) const {
    auto it = values_.find(key);
    if (it == values_.end()) {
        return default_value;
    }

    try {
        return std::stoi(it->second);
    } catch (...) {
        return default_value;
    }
}

float ConfigLoader::getFloat(const std::string& key, float default_value) const {
    auto it = values_.find(key);
    if (it == values_.end()) {
        return default_value;
    }

    try {
        return std::stof(it->second);
    } catch (...) {
        return default_value;
    }
}

bool ConfigLoader::getBool(const std::string& key, bool default_value) const {
    auto it = values_.find(key);
    if (it == values_.end()) {
        return default_value;
    }

    std::string value = it->second;
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });

    if (value == "1" || value == "true" || value == "yes" || value == "on") {
        return true;
    }
    if (value == "0" || value == "false" || value == "no" || value == "off") {
        return false;
    }

    return default_value;
}
