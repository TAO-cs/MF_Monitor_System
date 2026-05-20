#pragma once

#include <mosquitto.h>

#include <iostream>
#include <string>
#include <utility>

struct MqttConfig {
    bool enabled{false};
    std::string host{"127.0.0.1"};
    int port{1883};
    std::string client_id{"jetson-realtime-pipeline"};
    std::string username;
    std::string password;
    int keepalive_sec{30};
};

class MqttReporter {
public:
    explicit MqttReporter(MqttConfig config)
        : config_(std::move(config)) {}

    ~MqttReporter() {
        shutdown();
    }

    bool init() {
        if (!config_.enabled) {
            return true;
        }

        mosquitto_lib_init();
        lib_initialized_ = true;
        mosq_ = mosquitto_new(config_.client_id.c_str(), true, nullptr);
        if (!mosq_) {
            std::cerr << "[mqtt] failed to create mosquitto client\n";
            return false;
        }

        if (!config_.username.empty()) {
            mosquitto_username_pw_set(
                mosq_,
                config_.username.c_str(),
                config_.password.empty() ? nullptr : config_.password.c_str()
            );
        }

        int rc = mosquitto_connect(mosq_, config_.host.c_str(), config_.port, config_.keepalive_sec);
        if (rc != MOSQ_ERR_SUCCESS) {
            std::cerr << "[mqtt] connect failed: " << mosquitto_strerror(rc) << "\n";
            shutdown();
            return false;
        }

        rc = mosquitto_loop_start(mosq_);
        if (rc != MOSQ_ERR_SUCCESS) {
            std::cerr << "[mqtt] loop start failed: " << mosquitto_strerror(rc) << "\n";
            shutdown();
            return false;
        }

        connected_ = true;
        std::cout << "[mqtt] connected to " << config_.host << ":" << config_.port << "\n";
        return true;
    }

    bool publish(const std::string& topic, const std::string& payload, int qos = 1, bool retain = false) {
        if (!config_.enabled) {
            return true;
        }

        if (!mosq_ || !connected_) {
            std::cerr << "[mqtt] publish skipped because client is not connected\n";
            return false;
        }

        int rc = mosquitto_publish(
            mosq_,
            nullptr,
            topic.c_str(),
            static_cast<int>(payload.size()),
            payload.data(),
            qos,
            retain
        );
        if (rc != MOSQ_ERR_SUCCESS) {
            std::cerr << "[mqtt] publish failed: " << mosquitto_strerror(rc)
                      << ", topic=" << topic << "\n";
            return false;
        }

        return true;
    }

private:
    void shutdown() {
        if (mosq_) {
            if (connected_) {
                mosquitto_loop_stop(mosq_, true);
                mosquitto_disconnect(mosq_);
            }
            mosquitto_destroy(mosq_);
            mosq_ = nullptr;
        }
        if (lib_initialized_) {
            mosquitto_lib_cleanup();
            lib_initialized_ = false;
        }
        connected_ = false;
    }

    MqttConfig config_;
    mosquitto* mosq_{nullptr};
    bool connected_{false};
    bool lib_initialized_{false};
};
