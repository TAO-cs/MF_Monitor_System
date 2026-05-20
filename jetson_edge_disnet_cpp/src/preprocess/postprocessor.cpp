#include "preprocess/postprocessor.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

Postprocessor::Postprocessor(const std::vector<std::string>& class_names,
                             size_t stable_window,
                             float confidence_threshold)
    : class_names_(class_names),
      stable_window_(stable_window),
      confidence_threshold_(confidence_threshold) {
}

std::vector<float> Postprocessor::softmax(const std::vector<float>& logits) const {
    if (logits.empty()) {
        return {};
    }

    float max_logit = *std::max_element(logits.begin(), logits.end());

    std::vector<float> exps(logits.size(), 0.0f);
    float sum = 0.0f;
    for (size_t i = 0; i < logits.size(); ++i) {
        exps[i] = std::exp(logits[i] - max_logit);
        sum += exps[i];
    }

    std::vector<float> probs(logits.size(), 0.0f);
    if (sum <= 0.0f) {
        return probs;
    }

    for (size_t i = 0; i < logits.size(); ++i) {
        probs[i] = exps[i] / sum;
    }

    return probs;
}

bool Postprocessor::checkStable() const {
    if (recent_class_ids_.size() < stable_window_ || recent_confidences_.size() < stable_window_) {
        return false;
    }

    int first_id = recent_class_ids_.front();
    for (size_t i = 0; i < recent_class_ids_.size(); ++i) {
        if (recent_class_ids_[i] != first_id) {
            return false;
        }
        if (recent_confidences_[i] < confidence_threshold_) {
            return false;
        }
    }

    return true;
}

PostprocessResult Postprocessor::process(const std::vector<float>& logits) {
    if (logits.empty()) {
        throw std::runtime_error("Postprocessor received empty logits.");
    }

    std::vector<float> probs = softmax(logits);

    int class_id = 0;
    float confidence = probs[0];
    for (size_t i = 1; i < probs.size(); ++i) {
        if (probs[i] > confidence) {
            confidence = probs[i];
            class_id = static_cast<int>(i);
        }
    }

    std::string class_name = "unknown";
    if (class_id >= 0 && class_id < static_cast<int>(class_names_.size())) {
        class_name = class_names_[class_id];
    }

    recent_class_ids_.push_back(class_id);
    recent_confidences_.push_back(confidence);

    while (recent_class_ids_.size() > stable_window_) {
        recent_class_ids_.pop_front();
    }

    while (recent_confidences_.size() > stable_window_) {
        recent_confidences_.pop_front();
    }

    PostprocessResult result;
    result.class_id = class_id;
    result.class_name = class_name;
    result.confidence = confidence;
    result.probabilities = probs;
    result.is_stable = checkStable();

    return result;
}
