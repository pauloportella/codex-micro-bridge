#include "ride_bridge.h"

#include <Arduino.h>
#include <BLEAddress.h>
#include <BLEAdvertisedDevice.h>
#include <BLEClient.h>
#include <BLEDevice.h>
#include <BLERemoteCharacteristic.h>
#include <BLERemoteService.h>
#include <BLEScan.h>
#include <stdio.h>
#include <string.h>

#include "codex_hid_bridge.h"

namespace {

constexpr char kRideServiceUuid[] = "0000FC82-0000-1000-8000-00805F9B34FB";
constexpr char kLegacyServiceUuid[] = "00000001-19CA-4651-86E5-FA29DCDD09D1";
constexpr char kAsyncCharacteristicUuid[] =
    "00000002-19CA-4651-86E5-FA29DCDD09D1";
constexpr char kSyncRxCharacteristicUuid[] =
    "00000003-19CA-4651-86E5-FA29DCDD09D1";
constexpr char kSyncTxCharacteristicUuid[] =
    "00000004-19CA-4651-86E5-FA29DCDD09D1";
constexpr uint8_t kRideOn[] = {0x52, 0x69, 0x64, 0x65, 0x4f, 0x6e};
constexpr uint16_t kZwiftCompanyId = 0x094a;
constexpr uint8_t kRideLeftType = 0x08;
constexpr uint8_t kRideRightType = 0x07;
constexpr uint8_t kControllerNotification = 0x23;
constexpr uint32_t kHandshakeTimeoutMs = 5000;
constexpr size_t kNotificationQueueDepth = 16;

RideBridge* activeBridge = nullptr;

struct Mapping {
  const char* key;
  bool turn;
};

constexpr Mapping kMappings[] = {
    {"AG02", false},   // navigationLeft
    {"AG00", false},   // navigationUp
    {"AG03", false},   // navigationRight
    {"AG01", false},   // navigationDown
    {"AG04", false},   // a
    {"AG05", false},   // b
    {"ACT06", false},  // y
    {"ACT07", false},  // z
    {"ACT08", false},  // shiftUpLeft
    {"ACT09", false},  // shiftDownLeft
    {"ENC_CC", true},  // powerUpLeft
    {"ENC", false},    // onOffLeft
    {"ACT10", false},  // shiftUpRight
    {"ACT12", false},  // shiftDownRight
    {"ENC_CW", true},  // powerUpRight
    {"ACT10", false},  // onOffRight
    {"ENC_CC", true},  // paddleLeft
    {"ENC_CW", true},  // paddleRight
};

static_assert(sizeof(kMappings) / sizeof(kMappings[0]) ==
              static_cast<uint8_t>(RideButton::Count));

class ScanCallbacks final : public BLEAdvertisedDeviceCallbacks {
 public:
  void onResult(BLEAdvertisedDevice device) override {
    if (activeBridge != nullptr) activeBridge->handleAdvertisement(device);
  }
};

class ClientCallbacks final : public BLEClientCallbacks {
 public:
  void onConnect(BLEClient*) override {}

  void onDisconnect(BLEClient*) override {
    if (activeBridge != nullptr) activeBridge->handleDisconnect();
  }
};

void notificationCallback(BLERemoteCharacteristic* characteristic,
                          uint8_t* bytes, size_t length, bool) {
  if (activeBridge != nullptr) {
    activeBridge->handleNotification(characteristic, bytes, length);
  }
}

}  // namespace

void RideBridge::begin(CodexHidBridge* codex, StatusCallback onStatus) {
  codex_ = codex;
  onStatus_ = onStatus;
  activeBridge = this;
  scan_ = BLEDevice::getScan();
  scan_->setAdvertisedDeviceCallbacks(new ScanCallbacks(), false);
  scan_->setInterval(120);
  scan_->setWindow(80);
  scan_->setActiveScan(true);
  notificationQueue_ =
      xQueueCreate(kNotificationQueueDepth, sizeof(NotificationEvent));
  report("RIDE IDLE");
}

void RideBridge::poll() {
  pollNotifications();
  if (disconnected_) {
    disconnected_ = false;
    releaseAllButtons();
    connected_ = false;
    ready_ = false;
    asyncInput_ = nullptr;
    syncInput_ = nullptr;
    syncOutput_ = nullptr;
    handshakeEndsAtMs_ = 0;
    report("RIDE DISCONNECTED");
    if (scanEndsAtMs_ != 0 &&
        static_cast<int32_t>(scanEndsAtMs_ - millis()) > 0) {
      restartScanAtMs_ = millis() + 1000;
    }
  }
  if (connectPending_) connectPending();
  if (connected_ && !ready_ && handshakeEndsAtMs_ != 0 &&
      static_cast<int32_t>(millis() - handshakeEndsAtMs_) >= 0) {
    handshakeEndsAtMs_ = 0;
    report("RIDE HANDSHAKE TIMEOUT");
    client_->disconnect();
  }
  if (scanEndsAtMs_ != 0 &&
      static_cast<int32_t>(millis() - scanEndsAtMs_) >= 0) {
    if (scanning_) {
      scan_->stop();
      scan_->clearResults();
      scanning_ = false;
    }
    connectPending_ = false;
    delete candidate_;
    candidate_ = nullptr;
    scanEndsAtMs_ = 0;
    if (!connected_) report("RIDE SCAN TIMEOUT");
  }
  if (!connected_ && !scanning_ && !connectPending_ &&
      scanEndsAtMs_ != 0 &&
      static_cast<int32_t>(millis() - restartScanAtMs_) >= 0) {
    startScan();
  }
}

void RideBridge::scanFor(uint32_t durationMs) {
  if (connected_) {
    report(ready_ ? "RIDE STATUS READY" : "RIDE STATUS CONNECTED");
    return;
  }
  if (durationMs < 1000) durationMs = 1000;
  if (durationMs > 300000) durationMs = 300000;
  scanEndsAtMs_ = millis() + durationMs;
  restartScanAtMs_ = 0;
  if (!scanning_ && !connectPending_) startScan();

  char status[40]{};
  snprintf(status, sizeof(status), "RIDE SCAN %lu SECONDS",
           static_cast<unsigned long>(durationMs / 1000));
  report(status);
}

void RideBridge::stopScan() {
  scanEndsAtMs_ = 0;
  restartScanAtMs_ = 0;
  connectPending_ = false;
  delete candidate_;
  candidate_ = nullptr;
  if (scanning_) {
    scan_->stop();
    scan_->clearResults();
    scanning_ = false;
  }
  report("RIDE SCAN STOPPED");
}

void RideBridge::reportStatus() {
  if (ready_) {
    report("RIDE STATUS READY");
  } else if (connected_) {
    report("RIDE STATUS CONNECTED");
  } else if (connectPending_) {
    report("RIDE STATUS CONNECTING");
  } else if (scanning_) {
    report("RIDE STATUS SCANNING");
  } else {
    report("RIDE STATUS IDLE");
  }
  if (hidMuted_) report("RIDE HID MUTED");
}

void RideBridge::setHidMuted(bool muted) {
  if (hidMuted_ == muted) {
    report(muted ? "RIDE HID ALREADY MUTED" : "RIDE HID ALREADY ENABLED");
    return;
  }
  if (muted) hidMuted_ = true;
  releaseAllButtons();
  hidMuted_ = muted;
  report(muted ? "RIDE HID MUTED" : "RIDE HID ENABLED");
}

bool RideBridge::isConnected() const { return connected_; }

bool RideBridge::isReady() const { return ready_; }

bool RideBridge::isRidePeer(const uint8_t* address) const {
  return address != nullptr && hasRidePeerAddress_ &&
         memcmp(address, ridePeerAddress_, sizeof(ridePeerAddress_)) == 0;
}

void RideBridge::handleAdvertisement(BLEAdvertisedDevice device) {
  if (connected_ || connectPending_ || candidate_ != nullptr) return;

  int controllerType = -1;
  if (device.haveManufacturerData()) {
    const std::string data = device.getManufacturerData();
    if (data.size() >= 3) {
      const uint16_t company =
          static_cast<uint8_t>(data[0]) |
          (static_cast<uint16_t>(static_cast<uint8_t>(data[1])) << 8);
      if (company == kZwiftCompanyId) {
        controllerType = static_cast<uint8_t>(data[2]);
      }
    }
  }
  if (controllerType == kRideRightType) {
    report("RIDE FOUND RIGHT; WAITING FOR LEFT");
    return;
  }

  const bool hasRideService =
      device.isAdvertisingService(BLEUUID(kRideServiceUuid)) ||
      device.isAdvertisingService(BLEUUID(kLegacyServiceUuid));
  const bool namedRide = device.haveName() && device.getName() == "Zwift Ride";
  if (controllerType != kRideLeftType && !(namedRide && hasRideService)) return;

  scan_->stop();
  scanning_ = false;
  BLEAddress address = device.getAddress();
  memcpy(ridePeerAddress_, address.getNative(), sizeof(ridePeerAddress_));
  hasRidePeerAddress_ = true;
  candidate_ = new BLEAdvertisedDevice(device);
  connectPending_ = true;
  report("RIDE FOUND");
}

void RideBridge::handleDisconnect() { disconnected_ = true; }

void RideBridge::handleNotification(BLERemoteCharacteristic* characteristic,
                                    const uint8_t* bytes, size_t length) {
  if (notificationQueue_ == nullptr) return;
  NotificationEvent event{};
  if (characteristic == syncInput_) {
    if (length >= sizeof(kRideOn) &&
        memcmp(bytes, kRideOn, sizeof(kRideOn)) == 0) {
      event.type = NotificationType::Ready;
      if (xQueueSend(notificationQueue_, &event, 0) != pdTRUE) {
        ++droppedNotifications_;
      }
    }
    return;
  }
  if (characteristic != asyncInput_ || length < 2 ||
      bytes[0] != kControllerNotification) {
    return;
  }

  uint32_t current = 0;
  if (!decodeRideButtons(bytes + 1, length - 1, &current)) {
    event.type = NotificationType::Invalid;
  } else {
    event.type = NotificationType::Buttons;
    event.buttons = current;
  }
  if (xQueueSend(notificationQueue_, &event, 0) != pdTRUE) {
    ++droppedNotifications_;
  }
}

void RideBridge::pollNotifications() {
  if (notificationQueue_ == nullptr) return;
  NotificationEvent event{};
  while (xQueueReceive(notificationQueue_, &event, 0) == pdTRUE) {
    if (event.type == NotificationType::Ready) {
      ready_ = true;
      handshakeEndsAtMs_ = 0;
      scanEndsAtMs_ = 0;
      report("RIDE READY");
    } else if (event.type == NotificationType::Buttons) {
      if (ready_) emitChanges(event.buttons);
    } else {
      report("RIDE INVALID PACKET");
    }
  }
  if (droppedNotifications_ != 0) {
    const uint32_t dropped = droppedNotifications_;
    droppedNotifications_ = 0;
    releaseAllButtons();
    char status[64]{};
    snprintf(status, sizeof(status), "RIDE DROPPED %lu NOTIFICATION(S)",
             static_cast<unsigned long>(dropped));
    report(status);
  }
}

void RideBridge::startScan() {
  if (scan_ == nullptr || scanning_ || connected_ || connectPending_) return;
  scan_->clearResults();
  scanning_ = scan_->start(0, nullptr, false);
  report(scanning_ ? "RIDE SCANNING" : "RIDE SCAN FAILED");
  if (!scanning_) restartScanAtMs_ = millis() + 1000;
}

void RideBridge::connectPending() {
  connectPending_ = false;
  if (candidate_ == nullptr) return;
  report("RIDE CONNECTING");

  if (client_ == nullptr) {
    client_ = BLEDevice::createClient();
    client_->setClientCallbacks(new ClientCallbacks());
  }
  const bool didConnect = client_->connect(candidate_);
  delete candidate_;
  candidate_ = nullptr;
  if (!didConnect) {
    report("RIDE CONNECTION FAILED");
    restartScanAtMs_ = millis() + 1000;
    return;
  }

  BLERemoteService* service = client_->getService(BLEUUID(kRideServiceUuid));
  if (service == nullptr) {
    service = client_->getService(BLEUUID(kLegacyServiceUuid));
  }
  if (service == nullptr) {
    report("RIDE SERVICE MISSING");
    client_->disconnect();
    return;
  }

  asyncInput_ = service->getCharacteristic(BLEUUID(kAsyncCharacteristicUuid));
  syncOutput_ = service->getCharacteristic(BLEUUID(kSyncRxCharacteristicUuid));
  syncInput_ = service->getCharacteristic(BLEUUID(kSyncTxCharacteristicUuid));
  Serial.printf(
      "RIDE GATT async=%d notify=%d indicate=%d sync-in=%d notify=%d "
      "indicate=%d sync-out=%d write=%d write-nr=%d\n",
      asyncInput_ != nullptr,
      asyncInput_ != nullptr && asyncInput_->canNotify(),
      asyncInput_ != nullptr && asyncInput_->canIndicate(),
      syncInput_ != nullptr, syncInput_ != nullptr && syncInput_->canNotify(),
      syncInput_ != nullptr && syncInput_->canIndicate(), syncOutput_ != nullptr,
      syncOutput_ != nullptr && syncOutput_->canWrite(),
      syncOutput_ != nullptr && syncOutput_->canWriteNoResponse());
  if (asyncInput_ == nullptr || syncOutput_ == nullptr ||
      syncInput_ == nullptr ||
      (!asyncInput_->canNotify() && !asyncInput_->canIndicate()) ||
      (!syncInput_->canNotify() && !syncInput_->canIndicate()) ||
      (!syncOutput_->canWrite() && !syncOutput_->canWriteNoResponse())) {
    report("RIDE CHARACTERISTICS INCOMPLETE");
    client_->disconnect();
    return;
  }

  asyncInput_->registerForNotify(notificationCallback,
                                 asyncInput_->canNotify());
  syncInput_->registerForNotify(notificationCallback, syncInput_->canNotify());
  const bool requestResponse = !syncOutput_->canWriteNoResponse();
  syncOutput_->writeValue(const_cast<uint8_t*>(kRideOn), sizeof(kRideOn),
                          requestResponse);
  connected_ = true;
  handshakeEndsAtMs_ = millis() + kHandshakeTimeoutMs;
  report("RIDE HANDSHAKE SENT");
}

void RideBridge::releaseAllButtons() {
  const uint32_t previous = pressed_;
  pressed_ = 0;
  for (uint8_t index = 0; index < static_cast<uint8_t>(RideButton::Count);
       ++index) {
    const auto button = static_cast<RideButton>(index);
    if ((previous & rideButtonBit(button)) != 0) emitButton(button, false);
  }
}

void RideBridge::emitChanges(uint32_t current) {
  const uint32_t changed = current ^ pressed_;
  pressed_ = current;
  for (uint8_t index = 0; index < static_cast<uint8_t>(RideButton::Count);
       ++index) {
    const auto button = static_cast<RideButton>(index);
    const uint32_t bit = rideButtonBit(button);
    if ((changed & bit) != 0) emitButton(button, (current & bit) != 0);
  }
}

void RideBridge::emitButton(RideButton button, bool down) {
  const uint8_t index = static_cast<uint8_t>(button);
  if (index >= static_cast<uint8_t>(RideButton::Count)) return;
  const Mapping& mapping = kMappings[index];
  bool sent = true;
  if (hidMuted_) {
    sent = false;
  } else if (mapping.turn) {
    if (down) sent = codex_->sendKey(mapping.key, 2);
  } else {
    sent = codex_->sendKey(mapping.key, down ? 1 : 0);
  }

  char status[64]{};
  snprintf(status, sizeof(status), "RIDE BUTTON %s %s -> %s%s",
           rideButtonName(button), down ? "DOWN" : "UP", mapping.key,
           hidMuted_ ? " MUTED" : (sent ? "" : " FAILED"));
  report(status);
}

void RideBridge::report(const char* status) {
  if (onStatus_ != nullptr) {
    onStatus_(status);
  } else {
    Serial.println(status);
  }
}
