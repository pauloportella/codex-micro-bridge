#pragma once

#include <stddef.h>
#include <stdint.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#include "ride_protocol.h"

class BLEAdvertisedDevice;
class BLEClient;
class BLEScan;
class BLERemoteCharacteristic;
class CodexHidBridge;

class RideBridge {
 public:
  using StatusCallback = void (*)(const char* status);

  void begin(CodexHidBridge* codex, StatusCallback onStatus);
  void poll();
  void scanFor(uint32_t durationMs);
  void stopScan();
  void reportStatus();
  void setHidMuted(bool muted);

  bool isConnected() const;
  bool isReady() const;
  bool isRidePeer(const uint8_t* address) const;

  void handleAdvertisement(BLEAdvertisedDevice device);
  void handleDisconnect();
  void handleNotification(BLERemoteCharacteristic* characteristic,
                          const uint8_t* bytes, size_t length);

 private:
  enum class NotificationType : uint8_t {
    Ready,
    Buttons,
    Invalid,
  };

  struct NotificationEvent {
    NotificationType type;
    uint32_t buttons;
  };

  void startScan();
  void connectPending();
  void pollNotifications();
  void releaseAllButtons();
  void emitChanges(uint32_t current);
  void emitButton(RideButton button, bool down);
  void report(const char* status);

  CodexHidBridge* codex_ = nullptr;
  StatusCallback onStatus_ = nullptr;
  BLEScan* scan_ = nullptr;
  BLEClient* client_ = nullptr;
  BLEAdvertisedDevice* candidate_ = nullptr;
  BLERemoteCharacteristic* asyncInput_ = nullptr;
  BLERemoteCharacteristic* syncInput_ = nullptr;
  BLERemoteCharacteristic* syncOutput_ = nullptr;
  QueueHandle_t notificationQueue_ = nullptr;
  volatile bool connectPending_ = false;
  volatile bool disconnected_ = false;
  volatile uint32_t droppedNotifications_ = 0;
  bool scanning_ = false;
  bool connected_ = false;
  bool ready_ = false;
  bool hidMuted_ = false;
  uint32_t pressed_ = 0;
  uint32_t restartScanAtMs_ = 0;
  uint32_t scanEndsAtMs_ = 0;
  uint32_t handshakeEndsAtMs_ = 0;
  uint8_t ridePeerAddress_[6]{};
  bool hasRidePeerAddress_ = false;
};
