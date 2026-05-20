#pragma once

#include <deque>
#include <string>
#include <vector>

struct PostprocessResult {
    int class_id;
    std::string class_name;
    float confidence;
    std::vector<float> probabilities;
    bool is_stable;
};

class Postprocessor {
public:
    Postprocessor(const std::vector<std::string>& class_names,
                  size_t stable_window,
                  float confidence_threshold);

    PostprocessResult process(const std::vector<float>& logits);

private:
    std::vector<float> softmax(const std::vector<float>& logits) const;
    bool checkStable() const;

private:
    std::vector<std::string> class_names_;
    size_t stable_window_;
    float confidence_threshold_;

    std::deque<int> recent_class_ids_;
    std::deque<float> recent_confidences_;
};
