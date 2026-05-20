#pragma once

#include <string>
#include <unordered_map>

class ConfigLoader {
public:
    bool load(const std::string& path);

    std::string getString(const std::string& key, const std::string& default_value = "") const;
    int getInt(const std::string& key, int default_value) const;
    float getFloat(const std::string& key, float default_value) const;
    bool getBool(const std::string& key, bool default_value) const;

private:
    std::unordered_map<std::string, std::string> values_;
};
