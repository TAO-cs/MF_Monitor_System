#pragma once

#include "common/logger.hpp"

#include <mosquitto.h>

#include <chrono>
#include <string>
#include <thread>
#include <utility>

struct MqttConfig {
    bool enabled{true};
    std::string host{"127.0.0.1"};
    int port{1883};
    std::string client_id{"jetson-rtsp-probe"};
    std::string username;
    std::string password;
    int keepalive_sec{30};
    int reconnect_sec{3};
};

class MqttPublisher {
public:
    explicit MqttPublisher(MqttConfig config)
        : config_(std::move(config)) {
    }

    ~MqttPublisher() {
        shutdown();
    }

    bool init() {
        if (!config_.enabled) {
            return true;
        }

        mosquitto_lib_init();
        lib_initialized_ = true;

        client_ = mosquitto_new(config_.client_id.c_str(), true, this);
        if (!client_) {
            Logger::instance().error("[mqtt] failed to create mosquitto client");
            return false;
        }

        mosquitto_connect_callback_set(client_, &MqttPublisher::handleConnect);
        mosquitto_disconnect_callback_set(client_, &MqttPublisher::handleDisconnect);

        if (!config_.username.empty()) {
            mosquitto_username_pw_set(
                client_,
                config_.username.c_str(),
                config_.password.empty() ? nullptr : config_.password.c_str()
            );
        }

        int rc = mosquitto_connect(client_, config_.host.c_str(), config_.port, config_.keepalive_sec);
        if (rc != MOSQ_ERR_SUCCESS) {
            Logger::instance().error("[mqtt] connect failed: " + std::string(mosquitto_strerror(rc)));
            shutdown();
            return false;
        }

        rc = mosquitto_loop_start(client_);
        if (rc != MOSQ_ERR_SUCCESS) {
            Logger::instance().error("[mqtt] loop start failed: " + std::string(mosquitto_strerror(rc)));
            shutdown();
            return false;
        }

        for (int i = 0; i < 10; ++i) {
            if (connected_) {
                return true;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }

        Logger::instance().error("[mqtt] connect timed out");
        return false;
    }

    bool publish(const std::string& topic, const std::string& payload, int qos = 1, bool retain = false) {
        if (!config_.enabled) {
            return true;
        }

        if (!client_) {
            Logger::instance().warn("[mqtt] publish skipped because client is not initialized");
            return false;
        }

        if (!connected_ && !tryReconnect()) {
            Logger::instance().warn("[mqtt] publish skipped because reconnect failed");
            return false;
        }

        int rc = mosquitto_publish(
            client_,
            nullptr,
            topic.c_str(),
            static_cast<int>(payload.size()),
            payload.data(),
            qos,
            retain
        );

        if (rc != MOSQ_ERR_SUCCESS) {
            Logger::instance().warn(
                "[mqtt] publish failed: " + std::string(mosquitto_strerror(rc)) + " | topic=" + topic
            );

            connected_ = false;
            if (tryReconnect()) {
                rc = mosquitto_publish(
                    client_,
                    nullptr,
                    topic.c_str(),
                    static_cast<int>(payload.size()),
                    payload.data(),
                    qos,
                    retain
                );
                if (rc == MOSQ_ERR_SUCCESS) {
                    Logger::instance().info("[mqtt] publish recovered after reconnect | topic=" + topic);
                    return true;
                }
            }

            return false;
        }

        return true;
    }

private:
    static void handleConnect(struct mosquitto*, void* userdata, int rc) {
        auto* self = static_cast<MqttPublisher*>(userdata);
        if (!self) {
            return;
        }

        self->connected_ = (rc == MOSQ_ERR_SUCCESS);
        if (self->connected_) {
            Logger::instance().info(
                "[mqtt] connected to " + self->config_.host + ":" + std::to_string(self->config_.port)
            );
        } else {
            Logger::instance().error("[mqtt] connect callback error: " + std::string(mosquitto_strerror(rc)));
        }
    }

    static void handleDisconnect(struct mosquitto*, void* userdata, int rc) {
        auto* self = static_cast<MqttPublisher*>(userdata);
        if (!self) {
            return;
        }

        self->connected_ = false;
        if (rc != MOSQ_ERR_SUCCESS) {
            Logger::instance().warn("[mqtt] disconnected: " + std::string(mosquitto_strerror(rc)));
        } else {
            Logger::instance().info("[mqtt] disconnected");
        }
    }

    bool tryReconnect() {
        if (!client_) {
            return false;
        }

        Logger::instance().warn(
            "[mqtt] trying reconnect in " + std::to_string(config_.reconnect_sec) + " seconds..."
        );
        std::this_thread::sleep_for(std::chrono::seconds(config_.reconnect_sec));

        int rc = mosquitto_reconnect(client_);
        if (rc != MOSQ_ERR_SUCCESS) {
            Logger::instance().warn("[mqtt] reconnect failed: " + std::string(mosquitto_strerror(rc)));
            return false;
        }

        for (int i = 0; i < 10; ++i) {
            if (connected_) {
                return true;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }

        Logger::instance().warn("[mqtt] reconnect timed out");
        return false;
    }

    void shutdown() {
        if (client_) {
            if (connected_) {
                mosquitto_loop_stop(client_, true);
                mosquitto_disconnect(client_);
            }
            mosquitto_destroy(client_);
            client_ = nullptr;
        }

        if (lib_initialized_) {
            mosquitto_lib_cleanup();
            lib_initialized_ = false;
        }

        connected_ = false;
    }

    MqttConfig config_;
    mosquitto* client_{nullptr};
    bool connected_{false};
    bool lib_initialized_{false};
};
