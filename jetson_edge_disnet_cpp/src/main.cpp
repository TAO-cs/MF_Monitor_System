#include "common/config_loader.hpp"
#include "common/evidence_uploader.hpp"
#include "common/logger.hpp"
#include "common/snapshot_saver.hpp"
#include "infer/trt_engine.hpp"
#include "mqtt/mqtt_publisher.hpp"
#include "preprocess/frame_buffer.hpp"
#include "preprocess/postprocessor.hpp"
#include "preprocess/preprocessor.hpp"
#include "stream/rtsp_reader.hpp"

#include <chrono>
#include <ctime>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <algorithm>
#include <thread>
#include <vector>

#include <opencv2/opencv.hpp>

namespace {

std::string iso8601_now_beijing() {
    using namespace std::chrono;
    auto now = system_clock::now() + hours(8);
    std::time_t tt = system_clock::to_time_t(now);
    std::tm tm = *std::gmtime(&tt);

    std::ostringstream oss;
    oss << std::put_time(&tm, "%Y-%m-%dT%H:%M:%S+08:00");
    return oss.str();
}

std::string event_id_now() {
    using namespace std::chrono;
    auto now = system_clock::now() + hours(8);
    std::time_t tt = system_clock::to_time_t(now);
    std::tm tm = *std::gmtime(&tt);

    std::ostringstream oss;
    oss << "rt_" << std::put_time(&tm, "%Y%m%d_%H%M%S");
    return oss.str();
}

std::string resolvePathFromConfig(const std::string& config_path, const std::string& raw_path) {
    if (raw_path.empty()) {
        return raw_path;
    }

    namespace fs = std::filesystem;
    const fs::path candidate(raw_path);
    if (candidate.is_absolute()) {
        return candidate.lexically_normal().string();
    }

    const fs::path config_dir = fs::absolute(fs::path(config_path)).parent_path();
    return (config_dir / candidate).lexically_normal().string();
}

std::vector<std::string> splitClassNames(const std::string& raw_value) {
    std::vector<std::string> result;
    std::stringstream ss(raw_value);
    std::string item;
    while (std::getline(ss, item, ',')) {
        item.erase(item.begin(), std::find_if(item.begin(), item.end(), [](unsigned char ch) {
            return !std::isspace(ch);
        }));
        item.erase(std::find_if(item.rbegin(), item.rend(), [](unsigned char ch) {
            return !std::isspace(ch);
        }).base(), item.end());
        if (!item.empty()) {
            result.push_back(item);
        }
    }
    return result;
}

std::string build_device_status_payload(const std::string& aibox_id, const std::string& cam_id) {
    std::ostringstream oss;
    oss << "{"
        << "\"aibox_id\":\"" << aibox_id << "\","
        << "\"cam_id\":\"" << cam_id << "\","
        << "\"online_status\":\"on\","
        << "\"timestamp\":\"" << iso8601_now_beijing() << "\""
        << "}";
    return oss.str();
}

std::string build_classification_payload(
    const std::string& aibox_id,
    const std::string& cam_id,
    const std::string& class_name,
    float confidence,
    const std::string& image_path
) {
    std::ostringstream oss;
    oss << std::fixed << std::setprecision(4);
    oss << "{"
        << "\"disaster_id\":\"" << event_id_now() << "\","
        << "\"disaster_type\":\"" << class_name << "\","
        << "\"timestamp\":\"" << iso8601_now_beijing() << "\","
        << "\"confidence\":" << confidence << ","
        << "\"aibox_id\":\"" << aibox_id << "\","
        << "\"cam_id\":\"" << cam_id << "\","
        << "\"image_path\":";
    if (image_path.empty()) {
        oss << "null";
    } else {
        oss << "\"" << image_path << "\"";
    }
    oss << ""
        << "}";
    return oss.str();
}

}  // namespace

int main(int argc, char* argv[]) {
    std::string config_path = "configs/device.ini";
    if (argc > 1) {
        config_path = argv[1];
    }

    config_path = std::filesystem::absolute(std::filesystem::path(config_path)).lexically_normal().string();

    ConfigLoader config;
    if (!config.load(config_path)) {
        std::cerr << "Failed to load config file: " << config_path << std::endl;
        return 1;
    }

    std::string source = config.getString("rtsp_url", "rtsp://127.0.0.1:8554/mf001");
    std::string engine_path = config.getString("engine_path", "/home/nvidia/mudflow_project/model_onnx/EdgeDisNet_fp16.engine");
    std::string aibox_id = config.getString("aibox_id", "MF001");
    std::string cam_id = config.getString("cam_id", "CAM001");
    std::string mqtt_host = config.getString("mqtt_host", "127.0.0.1");
    int mqtt_port = config.getInt("mqtt_port", 1883);
    float confidence_threshold = config.getFloat("confidence_threshold", 0.80f);
    int stable_window = config.getInt("stable_window", 3);
    int cooldown_sec = config.getInt("cooldown_sec", 10);
    int status_interval_sec = config.getInt("status_interval_sec", 10);
    bool evidence_upload_enabled = config.getBool("evidence_upload_enabled", false);
    std::string evidence_upload_url = config.getString("evidence_upload_url", "");
    std::string evidence_upload_api_key = config.getString("evidence_upload_api_key", "");
    int evidence_upload_timeout_sec = config.getInt("evidence_upload_timeout_sec", 15);
    std::vector<std::string> class_names = splitClassNames(
        config.getString("class_names", "flood,mudslide")
    );
    std::string snapshot_dir = resolvePathFromConfig(
        config_path,
        config.getString("snapshot_dir", "runtime/snapshots")
    );
    std::string log_dir = resolvePathFromConfig(
        config_path,
        config.getString("log_dir", "runtime/logs")
    );
    int rtsp_reconnect_sec = config.getInt("rtsp_reconnect_sec", 3);
    int mqtt_reconnect_sec = config.getInt("mqtt_reconnect_sec", 3);

    if (argc > 2) {
        source = argv[2];
    }
    if (argc > 3) {
        engine_path = argv[3];
    }
    if (argc > 4) {
        aibox_id = argv[4];
    }
    if (argc > 5) {
        cam_id = argv[5];
    }
    if (argc > 6) {
        mqtt_host = argv[6];
    }
    if (argc > 7) {
        mqtt_port = std::stoi(argv[7]);
    }

    engine_path = resolvePathFromConfig(config_path, engine_path);

    Logger& logger = Logger::instance();
    if (!logger.initialize(log_dir)) {
        std::cerr << "Failed to initialize logger." << std::endl;
        return 1;
    }

    logger.info("Config path: " + config_path);
    logger.info("Log path: " + logger.logPath());

    RtspReader reader;
    while (!reader.open(source)) {
        logger.warn("Failed to open stream: " + source
                    + " | retrying in " + std::to_string(rtsp_reconnect_sec) + " seconds...");
        std::this_thread::sleep_for(std::chrono::seconds(rtsp_reconnect_sec));
    }

    logger.info("Opened stream: " + source);
    logger.info("Engine path: " + engine_path);
    logger.info("Device: " + aibox_id + " / " + cam_id);
    logger.info("MQTT: " + mqtt_host + ":" + std::to_string(mqtt_port));
    logger.info("Snapshot dir: " + snapshot_dir);
    logger.info("Evidence upload: " + std::string(evidence_upload_enabled ? "enabled" : "disabled"));
    if (evidence_upload_enabled) {
        logger.info("Evidence upload url: " + evidence_upload_url);
    }
    logger.info("RTSP reconnect sec: " + std::to_string(rtsp_reconnect_sec));
    logger.info("MQTT reconnect sec: " + std::to_string(mqtt_reconnect_sec));

    FrameBuffer frame_buffer(8, 4);
    Preprocessor preprocessor(240, 240);
    if (class_names.size() < 2) {
        class_names = {"flood", "mudslide"};
    }
    logger.info("Class names: " + class_names[0] + ", " + class_names[1]);
    Postprocessor postprocessor(class_names, static_cast<size_t>(stable_window), confidence_threshold);
    SnapshotSaver snapshot_saver(snapshot_dir);
    EvidenceUploadConfig evidence_config;
    evidence_config.enabled = evidence_upload_enabled;
    evidence_config.url = evidence_upload_url;
    evidence_config.api_key = evidence_upload_api_key;
    evidence_config.timeout_sec = evidence_upload_timeout_sec;
    EvidenceUploader evidence_uploader(evidence_config);

    MqttConfig mqtt_config;
    mqtt_config.enabled = true;
    mqtt_config.host = mqtt_host;
    mqtt_config.port = mqtt_port;
    mqtt_config.client_id = "jetson-" + aibox_id + "-" + cam_id;
    mqtt_config.reconnect_sec = mqtt_reconnect_sec;
    MqttPublisher mqtt_publisher(mqtt_config);
    if (!mqtt_publisher.init()) {
        logger.error("Failed to initialize MQTT publisher.");
        return 1;
    }

    TrtEngine trt_engine(engine_path);
    if (!trt_engine.initialize()) {
        logger.error("Failed to initialize TensorRT engine.");
        return 1;
    }

    logger.info("[TRT] Input size reported by engine: " + std::to_string(trt_engine.getInputSize()));
    logger.info("[TRT] Output size reported by engine: " + std::to_string(trt_engine.getOutputSize()));

    const std::string topic_prefix = "disaster_monitoring";
    const std::string status_topic = topic_prefix + "/" + aibox_id + "/device_status";
    const std::string classification_topic = topic_prefix + "/" + aibox_id + "/classification";

    const auto status_interval = std::chrono::seconds(status_interval_sec);
    const auto classification_cooldown = std::chrono::seconds(cooldown_sec);
    auto last_status_publish = std::chrono::steady_clock::now() - status_interval;
    auto last_classification_publish = std::chrono::steady_clock::now() - classification_cooldown;
    std::string last_published_class;

    auto last_time = std::chrono::steady_clock::now();
    int frame_count = 0;
    int total_frame_index = 0;

    while (true) {
        cv::Mat frame;
        if (!reader.read(frame)) {
            logger.warn("[rtsp] failed to read frame, trying to reconnect in "
                        + std::to_string(rtsp_reconnect_sec) + " seconds...");
            reader.close();
            std::this_thread::sleep_for(std::chrono::seconds(rtsp_reconnect_sec));
            if (!reader.reopen()) {
                logger.warn("[rtsp] reconnect failed.");
                continue;
            }

            logger.info("[rtsp] reconnect succeeded.");
            continue;
        }

        if (frame.empty()) {
            logger.warn("[rtsp] empty frame received, trying to reconnect in "
                        + std::to_string(rtsp_reconnect_sec) + " seconds...");
            reader.close();
            std::this_thread::sleep_for(std::chrono::seconds(rtsp_reconnect_sec));
            if (!reader.reopen()) {
                logger.warn("[rtsp] reconnect failed.");
                continue;
            }

            logger.info("[rtsp] reconnect succeeded.");
            continue;
        }

        total_frame_index++;
        frame_count++;

        frame_buffer.push(frame);

        auto now = std::chrono::steady_clock::now();
        double elapsed_sec = std::chrono::duration<double>(now - last_time).count();

        if (now - last_status_publish >= status_interval) {
            const std::string payload = build_device_status_payload(aibox_id, cam_id);
            if (mqtt_publisher.publish(status_topic, payload, 1, false)) {
                logger.info("[mqtt] device_status published");
                last_status_publish = now;
            }
        }

        if (elapsed_sec >= 1.0) {
            double fps = frame_count / elapsed_sec;
            std::cout << "[STREAM] FPS: " << fps
                      << " | Resolution: " << frame.cols << "x" << frame.rows
                      << " | Buffer size: " << frame_buffer.size()
                      << std::endl;

            frame_count = 0;
            last_time = now;
        }

        if (frame_buffer.shouldInfer()) {
            std::vector<cv::Mat> window = frame_buffer.getWindow();
            std::vector<float> input_tensor = preprocessor.process(window);

            std::vector<float> output_logits;
            if (!trt_engine.infer(input_tensor, output_logits)) {
                logger.error("[TRT] Inference failed at frame index " + std::to_string(total_frame_index));
                break;
            }

            PostprocessResult result = postprocessor.process(output_logits);

            std::cout << "[POST] Total frame index: " << total_frame_index
                      << " | class_id: " << result.class_id
                      << " | class_name: " << result.class_name
                      << " | confidence: " << result.confidence
                      << " | stable: " << (result.is_stable ? "yes" : "no");

            if (result.probabilities.size() >= 2) {
                std::cout << " | probs: [" << result.probabilities[0]
                          << ", " << result.probabilities[1] << "]";
            }

            std::cout << std::endl;

            if (result.is_stable) {
                bool cooldown_ok = (now - last_classification_publish) >= classification_cooldown;
                bool class_changed = result.class_name != last_published_class;

                if (cooldown_ok || class_changed) {
                    std::string image_path = snapshot_saver.save(frame, aibox_id, cam_id);
                    std::string published_image_path = image_path;
                    if (!image_path.empty()) {
                        const std::string uploaded_image_url = evidence_uploader.upload(image_path, aibox_id, cam_id);
                        if (!uploaded_image_url.empty()) {
                            published_image_path = uploaded_image_url;
                        }
                    }
                    const std::string payload = build_classification_payload(
                        aibox_id,
                        cam_id,
                        result.class_name,
                        result.confidence,
                        published_image_path
                    );

                    if (mqtt_publisher.publish(classification_topic, payload, 1, false)) {
                        logger.info(
                            "[mqtt] classification published"
                            " | class=" + result.class_name
                            + " | confidence=" + std::to_string(result.confidence)
                            + " | image_path=" + (published_image_path.empty() ? std::string("null") : published_image_path)
                        );
                        last_classification_publish = now;
                        last_published_class = result.class_name;
                    }
                }
            }

            frame_buffer.markInferConsumed();
        }
    }

    reader.close();
    logger.info("Application stopped.");
    return 0;
}
