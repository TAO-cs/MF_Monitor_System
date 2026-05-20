#include "mqtt_reporter.hpp"
#include "trt_engine.hpp"

#include <opencv2/opencv.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <ctime>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

namespace {

struct AppConfig {
    std::string source{"rtsp://127.0.0.1:8554/mf001"};
    std::string engine_path{"/mudflow_project/model_onnx/EdgeDisNet_fp16.engine"};
    std::string aibox_id{"MF001"};
    std::string cam_id{"CAM001"};
    std::vector<std::string> class_names{"flood", "mudslide"};

    int input_width{240};
    int input_height{240};
    int num_frames{8};
    int stride{4};

    float confidence_threshold{0.80F};
    int stable_windows{3};
    int publish_cooldown_sec{8};
    int device_status_interval_sec{10};
    int print_stats_interval_sec{1};

    bool show_window{false};
    bool mqtt_enabled{true};
    std::string mqtt_host{"127.0.0.1"};
    int mqtt_port{1883};
    std::string mqtt_username;
    std::string mqtt_password;
    std::string mqtt_client_id{"jetson-realtime-pipeline"};
    std::string topic_prefix{"disaster_monitoring"};
    std::string save_debug_dir{"/mudflow_project/debug_frames"};
};

struct InferenceResult {
    int class_id{-1};
    std::string class_name{"unknown"};
    float confidence{0.0F};
    std::vector<float> probabilities;
    double infer_ms{0.0};
};

struct StableDecision {
    int class_id{-1};
    std::string class_name;
    float average_confidence{0.0F};
};

std::string json_escape(const std::string& input) {
    std::ostringstream oss;
    for (char ch : input) {
        switch (ch) {
            case '\\': oss << "\\\\"; break;
            case '"': oss << "\\\""; break;
            case '\n': oss << "\\n"; break;
            case '\r': oss << "\\r"; break;
            case '\t': oss << "\\t"; break;
            default: oss << ch; break;
        }
    }
    return oss.str();
}

std::tm local_tm_now() {
    const std::time_t now = std::time(nullptr);
    std::tm tm_value{};
#ifdef _WIN32
    localtime_s(&tm_value, &now);
#else
    localtime_r(&now, &tm_value);
#endif
    return tm_value;
}

std::string now_iso8601_local() {
    const std::tm tm_value = local_tm_now();
    std::ostringstream oss;
    oss << std::put_time(&tm_value, "%Y-%m-%dT%H:%M:%S%z");
    std::string value = oss.str();
    if (value.size() >= 5) {
        value.insert(value.size() - 2, ":");
    }
    return value;
}

std::string now_compact() {
    const std::tm tm_value = local_tm_now();
    std::ostringstream oss;
    oss << std::put_time(&tm_value, "%Y%m%d_%H%M%S");
    return oss.str();
}

std::string generate_disaster_id() {
    static int sequence = 0;
    sequence = (sequence + 1) % 10000;
    std::ostringstream oss;
    oss << "rt_" << now_compact() << "_" << std::setw(4) << std::setfill('0') << sequence;
    return oss.str();
}

std::vector<float> softmax(const std::vector<float>& logits) {
    if (logits.empty()) {
        return {};
    }

    const float max_logit = *std::max_element(logits.begin(), logits.end());
    std::vector<float> exps(logits.size(), 0.0F);
    std::transform(logits.begin(), logits.end(), exps.begin(), [max_logit](float value) {
        return std::exp(value - max_logit);
    });
    const float sum = std::accumulate(exps.begin(), exps.end(), 0.0F);
    if (sum <= 0.0F) {
        return std::vector<float>(logits.size(), 0.0F);
    }
    for (float& value : exps) {
        value /= sum;
    }
    return exps;
}

InferenceResult decode_result(const std::vector<float>& logits, const std::vector<std::string>& class_names, double infer_ms) {
    InferenceResult result;
    result.probabilities = softmax(logits);
    result.infer_ms = infer_ms;

    if (result.probabilities.empty()) {
        return result;
    }

    const auto it = std::max_element(result.probabilities.begin(), result.probabilities.end());
    result.class_id = static_cast<int>(std::distance(result.probabilities.begin(), it));
    result.confidence = *it;
    if (result.class_id >= 0 && result.class_id < static_cast<int>(class_names.size())) {
        result.class_name = class_names[static_cast<size_t>(result.class_id)];
    }
    return result;
}

class StableDecisionTracker {
public:
    StableDecisionTracker(int window_size, float threshold)
        : window_size_(window_size), threshold_(threshold) {}

    std::optional<StableDecision> update(const InferenceResult& result) {
        if (window_size_ <= 0) {
            return std::nullopt;
        }

        class_history_.push_back(result.class_id);
        confidence_history_.push_back(result.confidence);
        while (class_history_.size() > static_cast<size_t>(window_size_)) {
            class_history_.pop_front();
            confidence_history_.pop_front();
        }

        if (class_history_.size() < static_cast<size_t>(window_size_)) {
            return std::nullopt;
        }

        const int target_class = class_history_.front();
        if (std::any_of(class_history_.begin(), class_history_.end(), [target_class](int value) {
                return value != target_class;
            })) {
            return std::nullopt;
        }

        const float min_conf = *std::min_element(confidence_history_.begin(), confidence_history_.end());
        if (min_conf < threshold_) {
            return std::nullopt;
        }

        const float avg_conf =
            std::accumulate(confidence_history_.begin(), confidence_history_.end(), 0.0F) /
            static_cast<float>(confidence_history_.size());

        StableDecision decision;
        decision.class_id = target_class;
        decision.average_confidence = avg_conf;
        return decision;
    }

private:
    int window_size_;
    float threshold_;
    std::deque<int> class_history_;
    std::deque<float> confidence_history_;
};

std::vector<float> preprocess_window(
    const std::deque<cv::Mat>& frame_window,
    int input_h,
    int input_w
) {
    constexpr float mean[3] = {0.485F, 0.456F, 0.406F};
    constexpr float stdv[3] = {0.229F, 0.224F, 0.225F};

    std::vector<float> tensor(static_cast<size_t>(frame_window.size()) * 3U *
                              static_cast<size_t>(input_h) * static_cast<size_t>(input_w), 0.0F);

    for (size_t frame_idx = 0; frame_idx < frame_window.size(); ++frame_idx) {
        cv::Mat rgb;
        cv::cvtColor(frame_window[frame_idx], rgb, cv::COLOR_BGR2RGB);

        cv::Mat resized;
        cv::resize(rgb, resized, cv::Size(input_w, input_h), 0.0, 0.0, cv::INTER_CUBIC);

        cv::Mat float_img;
        resized.convertTo(float_img, CV_32FC3, 1.0 / 255.0);

        std::vector<cv::Mat> channels;
        cv::split(float_img, channels);

        const size_t frame_offset = frame_idx * 3U * static_cast<size_t>(input_h) * static_cast<size_t>(input_w);
        const size_t channel_stride = static_cast<size_t>(input_h) * static_cast<size_t>(input_w);

        for (int c = 0; c < 3; ++c) {
            for (int y = 0; y < input_h; ++y) {
                for (int x = 0; x < input_w; ++x) {
                    const float normalized = (channels[c].at<float>(y, x) - mean[c]) / stdv[c];
                    const size_t index = frame_offset + static_cast<size_t>(c) * channel_stride +
                                         static_cast<size_t>(y) * static_cast<size_t>(input_w) +
                                         static_cast<size_t>(x);
                    tensor[index] = normalized;
                }
            }
        }
    }

    return tensor;
}

std::string build_status_payload(const AppConfig& config) {
    std::ostringstream oss;
    oss << "{"
        << "\"aibox_id\":\"" << json_escape(config.aibox_id) << "\","
        << "\"cam_id\":\"" << json_escape(config.cam_id) << "\","
        << "\"online_status\":\"on\","
        << "\"timestamp\":\"" << now_iso8601_local() << "\""
        << "}";
    return oss.str();
}

std::string build_classification_payload(
    const AppConfig& config,
    const StableDecision& decision,
    const std::string& image_path
) {
    std::ostringstream oss;
    oss << "{"
        << "\"disaster_id\":\"" << generate_disaster_id() << "\","
        << "\"disaster_type\":\"" << json_escape(decision.class_name) << "\","
        << "\"timestamp\":\"" << now_iso8601_local() << "\","
        << "\"confidence\":" << std::fixed << std::setprecision(4) << decision.average_confidence << ","
        << "\"aibox_id\":\"" << json_escape(config.aibox_id) << "\","
        << "\"cam_id\":\"" << json_escape(config.cam_id) << "\"";
    if (!image_path.empty()) {
        oss << ",\"image_path\":\"" << json_escape(image_path) << "\"";
    }
    oss << "}";
    return oss.str();
}

std::string save_debug_frame(const AppConfig& config, const cv::Mat& frame) {
    if (config.save_debug_dir.empty()) {
        return {};
    }

    fs::create_directories(config.save_debug_dir);
    const fs::path target = fs::path(config.save_debug_dir) / ("frame_" + now_compact() + ".jpg");
    if (!cv::imwrite(target.string(), frame)) {
        std::cerr << "[debug] failed to save frame: " << target << "\n";
        return {};
    }
    return target.string();
}

void draw_overlay(
    cv::Mat& frame,
    const InferenceResult& result,
    double stream_fps,
    bool connected
) {
    std::ostringstream line1;
    line1 << "class=" << result.class_name << " conf=" << std::fixed << std::setprecision(3) << result.confidence;

    std::ostringstream line2;
    line2 << "infer_ms=" << std::fixed << std::setprecision(2) << result.infer_ms
          << " stream_fps=" << std::fixed << std::setprecision(2) << stream_fps
          << " mqtt=" << (connected ? "on" : "off");

    cv::putText(frame, line1.str(), cv::Point(20, 40), cv::FONT_HERSHEY_SIMPLEX, 0.8, cv::Scalar(0, 255, 0), 2);
    cv::putText(frame, line2.str(), cv::Point(20, 75), cv::FONT_HERSHEY_SIMPLEX, 0.7, cv::Scalar(0, 255, 255), 2);
}

bool is_gstreamer_pipeline(const std::string& source) {
    return source.find("rtspsrc") != std::string::npos || source.find("appsink") != std::string::npos;
}

bool open_capture(const AppConfig& config, cv::VideoCapture& cap) {
    if (is_gstreamer_pipeline(config.source)) {
        return cap.open(config.source, cv::CAP_GSTREAMER);
    }
    if (cap.open(config.source, cv::CAP_FFMPEG)) {
        return true;
    }
    return cap.open(config.source, cv::CAP_ANY);
}

}  // namespace

int main(int argc, char** argv) {
    const std::string keys =
        "{help h usage ? |             | print help }"
        "{source         | rtsp://127.0.0.1:8554/mf001 | RTSP url or GStreamer pipeline }"
        "{engine         | /mudflow_project/model_onnx/EdgeDisNet_fp16.engine | TensorRT engine path }"
        "{aibox_id       | MF001       | device aibox id }"
        "{cam_id         | CAM001      | device camera id }"
        "{mqtt           | 1           | enable mqtt publish: 1 or 0 }"
        "{mqtt_host      | 127.0.0.1   | mqtt host }"
        "{mqtt_port      | 1883        | mqtt port }"
        "{mqtt_user      |             | mqtt username }"
        "{mqtt_password  |             | mqtt password }"
        "{mqtt_client_id | jetson-realtime-pipeline | mqtt client id }"
        "{topic_prefix   | disaster_monitoring | topic prefix }"
        "{input_width    | 240         | input width }"
        "{input_height   | 240         | input height }"
        "{num_frames     | 8           | temporal frames per window }"
        "{stride         | 4           | infer every N frames }"
        "{threshold      | 0.80        | classification confidence threshold }"
        "{stable_windows | 3           | stable decision window count }"
        "{cooldown_sec   | 8           | classification publish cooldown seconds }"
        "{status_sec     | 10          | device_status publish interval seconds }"
        "{show           | 0           | display preview window: 1 or 0 }"
        "{save_debug_dir | /mudflow_project/debug_frames | save event frame dir }";

    cv::CommandLineParser parser(argc, argv, keys);
    if (parser.has("help")) {
        parser.printMessage();
        return 0;
    }

    AppConfig config;
    config.source = parser.get<std::string>("source");
    config.engine_path = parser.get<std::string>("engine");
    config.aibox_id = parser.get<std::string>("aibox_id");
    config.cam_id = parser.get<std::string>("cam_id");
    config.mqtt_enabled = parser.get<int>("mqtt") != 0;
    config.mqtt_host = parser.get<std::string>("mqtt_host");
    config.mqtt_port = parser.get<int>("mqtt_port");
    config.mqtt_username = parser.get<std::string>("mqtt_user");
    config.mqtt_password = parser.get<std::string>("mqtt_password");
    config.mqtt_client_id = parser.get<std::string>("mqtt_client_id");
    config.topic_prefix = parser.get<std::string>("topic_prefix");
    config.input_width = parser.get<int>("input_width");
    config.input_height = parser.get<int>("input_height");
    config.num_frames = parser.get<int>("num_frames");
    config.stride = parser.get<int>("stride");
    config.confidence_threshold = parser.get<float>("threshold");
    config.stable_windows = parser.get<int>("stable_windows");
    config.publish_cooldown_sec = parser.get<int>("cooldown_sec");
    config.device_status_interval_sec = parser.get<int>("status_sec");
    config.show_window = parser.get<int>("show") != 0;
    config.save_debug_dir = parser.get<std::string>("save_debug_dir");

    if (!parser.check()) {
        parser.printErrors();
        return 1;
    }

    if (!fs::exists(config.engine_path)) {
        std::cerr << "[main] engine path does not exist: " << config.engine_path << "\n";
        return 1;
    }

    trtapp::TrtEngine engine;
    if (!engine.load(config.engine_path, config.num_frames, config.input_height, config.input_width)) {
        return 1;
    }

    MqttConfig mqtt_config;
    mqtt_config.enabled = config.mqtt_enabled;
    mqtt_config.host = config.mqtt_host;
    mqtt_config.port = config.mqtt_port;
    mqtt_config.username = config.mqtt_username;
    mqtt_config.password = config.mqtt_password;
    mqtt_config.client_id = config.mqtt_client_id;

    MqttReporter reporter(mqtt_config);
    if (!reporter.init()) {
        return 1;
    }

    cv::VideoCapture cap;
    if (!open_capture(config, cap)) {
        std::cerr << "[main] failed to open source: " << config.source << "\n";
        return 1;
    }

    std::cout << "[main] source opened: " << config.source << "\n";
    std::cout << "[main] classes: " << config.class_names[0] << ", " << config.class_names[1] << "\n";

    StableDecisionTracker tracker(config.stable_windows, config.confidence_threshold);
    std::deque<cv::Mat> frame_window;

    const std::string status_topic =
        config.topic_prefix + "/" + config.aibox_id + "/device_status";
    const std::string classification_topic =
        config.topic_prefix + "/" + config.aibox_id + "/classification";

    auto last_status_publish = std::chrono::steady_clock::now() - std::chrono::seconds(config.device_status_interval_sec);
    auto last_class_publish = std::chrono::steady_clock::now() - std::chrono::seconds(config.publish_cooldown_sec);
    auto last_stats_print = std::chrono::steady_clock::now();

    int64_t frame_index = 0;
    int frames_in_period = 0;
    double stream_fps = 0.0;
    int last_published_class = -1;
    InferenceResult latest_result;

    while (true) {
        cv::Mat frame;
        if (!cap.read(frame) || frame.empty()) {
            std::cerr << "[stream] frame read failed, retrying...\n";
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            continue;
        }

        ++frame_index;
        ++frames_in_period;

        frame_window.push_back(frame.clone());
        while (frame_window.size() > static_cast<size_t>(config.num_frames)) {
            frame_window.pop_front();
        }

        const auto now = std::chrono::steady_clock::now();
        const auto stats_elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - last_stats_print).count();
        if (stats_elapsed >= config.print_stats_interval_sec) {
            stream_fps = static_cast<double>(frames_in_period) / static_cast<double>(stats_elapsed);
            std::cout << "[stream] fps=" << std::fixed << std::setprecision(2) << stream_fps
                      << " resolution=" << frame.cols << "x" << frame.rows
                      << " frame_index=" << frame_index << "\n";
            frames_in_period = 0;
            last_stats_print = now;
        }

        if (std::chrono::duration_cast<std::chrono::seconds>(now - last_status_publish).count() >=
            config.device_status_interval_sec) {
            reporter.publish(status_topic, build_status_payload(config), 1, false);
            last_status_publish = now;
        }

        const bool ready_for_infer =
            frame_window.size() == static_cast<size_t>(config.num_frames) &&
            (frame_index % config.stride == 0);

        if (ready_for_infer) {
            const std::vector<float> input_tensor =
                preprocess_window(frame_window, config.input_height, config.input_width);

            std::vector<float> logits;
            double infer_ms = 0.0;
            if (!engine.infer(input_tensor, logits, infer_ms)) {
                std::cerr << "[infer] inference failed\n";
                continue;
            }

            latest_result = decode_result(logits, config.class_names, infer_ms);
            std::cout << "[infer] class=" << latest_result.class_name
                      << " confidence=" << std::fixed << std::setprecision(4) << latest_result.confidence
                      << " infer_ms=" << std::setprecision(2) << latest_result.infer_ms << "\n";

            auto stable_decision = tracker.update(latest_result);
            if (stable_decision.has_value()) {
                stable_decision->class_name =
                    config.class_names[static_cast<size_t>(stable_decision->class_id)];

                const bool cooldown_ok =
                    std::chrono::duration_cast<std::chrono::seconds>(now - last_class_publish).count() >=
                    config.publish_cooldown_sec;
                const bool class_changed = stable_decision->class_id != last_published_class;

                if (cooldown_ok || class_changed) {
                    const std::string image_path = save_debug_frame(config, frame);
                    const std::string payload =
                        build_classification_payload(config, *stable_decision, image_path);
                    if (reporter.publish(classification_topic, payload, 1, false)) {
                        last_class_publish = now;
                        last_published_class = stable_decision->class_id;
                        std::cout << "[mqtt] classification published: class="
                                  << stable_decision->class_name
                                  << " avg_conf=" << std::fixed << std::setprecision(4)
                                  << stable_decision->average_confidence << "\n";
                    }
                }
            }
        }

        if (config.show_window) {
            cv::Mat vis = frame.clone();
            draw_overlay(vis, latest_result, stream_fps, config.mqtt_enabled);
            cv::imshow("jetson_realtime_pipeline", vis);
            const int key = cv::waitKey(1);
            if (key == 'q' || key == 27) {
                break;
            }
        }
    }

    cap.release();
    cv::destroyAllWindows();
    return 0;
}
