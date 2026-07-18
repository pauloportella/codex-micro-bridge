#include "codex_hid_bridge.h"

#include <Arduino.h>
#include <BLECharacteristic.h>
#include <BLEHIDDevice.h>
#include <BLEServer.h>
#include <stdlib.h>
#include <string.h>

#include "codex_rpc_protocol.h"
#include "firmware_version.h"

namespace {

constexpr uint8_t kReportId = 6;
constexpr uint8_t kRpcChannel = 2;
constexpr size_t kReportValueBytes = 63;
constexpr size_t kPayloadBytes = 61;

static_assert(kReportValueBytes == kPayloadBytes + 2);

constexpr uint16_t byteSwap16(uint16_t value) {
  return static_cast<uint16_t>((value >> 8) | (value << 8));
}

uint8_t kReportMap[] = {
    0x06, 0x00, 0xff,        // Usage Page (Vendor 0xff00)
    0x09, 0x01,              // Usage 1
    0xa1, 0x01,              // Collection (Application)
    0x85, 0x06,              // Report ID 6
    0x15, 0x00,              // Logical minimum 0
    0x26, 0xff, 0x00,        // Logical maximum 255
    0x75, 0x08,              // Report size 8
    0x95, 0x3f,              // Report count 63
    0x09, 0x01, 0x81, 0x02,  // Input (Data, Variable, Absolute)
    0x09, 0x01, 0x91, 0x02,  // Output (Data, Variable, Absolute)
    0xc0,                    // End collection
};

bool validKey(const char* key) {
  if (key == nullptr || *key == '\0') return false;
  for (const char* cursor = key; *cursor != '\0'; ++cursor) {
    if (!((*cursor >= 'A' && *cursor <= 'Z') ||
          (*cursor >= '0' && *cursor <= '9') || *cursor == '_')) {
      return false;
    }
  }
  return true;
}

class OutputCallbacks final : public BLECharacteristicCallbacks {
 public:
  explicit OutputCallbacks(CodexHidBridge* bridge) : bridge_(bridge) {}

  void onWrite(BLECharacteristic* characteristic) override {
    const std::string value = characteristic->getValue();
    if (!value.empty()) {
      bridge_->receiveOutput(reinterpret_cast<const uint8_t*>(value.data()),
                             value.size());
    }
  }

 private:
  CodexHidBridge* bridge_;
};

}  // namespace

void CodexHidBridge::begin(BLEServer* server, RpcCallback onRpc) {
  onRpc_ = onRpc;
  hidDevice_ = new BLEHIDDevice(server);
  inputReport_ = hidDevice_->inputReport(kReportId);
  outputReport_ = hidDevice_->outputReport(kReportId);
  outputReport_->setCallbacks(new OutputCallbacks(this));
  hidDevice_->manufacturer()->setValue("Work Louder");
  // BLEHIDDevice::pnp writes each uint16_t most-significant byte first, while
  // the Bluetooth Device Information Service requires these fields little
  // endian. Swap the inputs so macOS reads the intended Codex Micro IDs.
  hidDevice_->pnp(
      0x02, byteSwap16(0x303a), byteSwap16(0x8360), byteSwap16(0x0001));
  hidDevice_->hidInfo(0x00, 0x02);
  hidDevice_->reportMap(kReportMap, sizeof(kReportMap));
  hidDevice_->startServices();
  hidDevice_->setBatteryLevel(100);
}

void CodexHidBridge::setConnected(bool connected) {
  connected_ = connected;
  if (!connected) resetRpc();
}

bool CodexHidBridge::isConnected() const { return connected_; }

bool CodexHidBridge::sendKey(const char* key, int action, int agent) {
  if (!validKey(key) || action < 0 || action > 2 || agent < -1) return false;
  char message[128]{};
  if (agent >= 0) {
    snprintf(message, sizeof(message),
             "{\"method\":\"v.oai.hid\",\"params\":{\"k\":\"%s\",\"act\":%d,"
             "\"ag\":%d}}\n",
             key, action, agent);
  } else {
    snprintf(
        message, sizeof(message),
        "{\"method\":\"v.oai.hid\",\"params\":{\"k\":\"%s\",\"act\":%d}}\n",
        key, action);
  }
  return sendRpc(message);
}

bool CodexHidBridge::press(const char* key, uint32_t durationMs, int agent) {
  if (!sendKey(key, 1, agent)) return false;
  delay(durationMs == 0 ? 1 : durationMs);
  return sendKey(key, 0, agent);
}

void CodexHidBridge::receiveOutput(const uint8_t* bytes, size_t length) {
  if (bytes == nullptr || length == 0) return;
  if (bytes[0] == kReportId) {
    ++bytes;
    --length;
  }
  if (length < 2 || bytes[0] != kRpcChannel) return;
  const size_t payloadLength =
      min(static_cast<size_t>(bytes[1]), kPayloadBytes);
  if (length < payloadLength + 2) return;
  consumeRpcBytes(bytes + 2, payloadLength);
}

bool CodexHidBridge::sendRpc(const char* json) {
  if (!connected_ || inputReport_ == nullptr || json == nullptr) return false;
  const size_t length = strlen(json);
  for (size_t offset = 0; offset < length; offset += kPayloadBytes) {
    const size_t chunk = min(kPayloadBytes, length - offset);
    uint8_t report[kReportValueBytes]{};
    report[0] = kRpcChannel;
    report[1] = static_cast<uint8_t>(chunk);
    memcpy(report + 2, json + offset, chunk);
    inputReport_->setValue(report, sizeof(report));
    inputReport_->notify();
  }
  return true;
}

void CodexHidBridge::consumeRpcBytes(const uint8_t* bytes, size_t length) {
  for (size_t index = 0; index < length; ++index) {
    const char byte = static_cast<char>(bytes[index]);
    if (byte == '\0') continue;

    if (byte == '\n' || byte == '\r') {
      if (rpcStarted_) {
        Serial.println(F("CODEX RPC MALFORMED; RESET"));
        resetRpc();
      }
      continue;
    }

    if (!rpcStarted_) {
      if (byte != '{') continue;
      currentRpcLength_ = 0;
      currentRpcTruncated_ = false;
      rpcStarted_ = true;
      rpcInString_ = false;
      rpcEscape_ = false;
      rpcDepth_ = 1;
      appendRpcByte(byte);
      continue;
    }

    appendRpcByte(byte);
    if (rpcInString_) {
      if (rpcEscape_) {
        rpcEscape_ = false;
      } else if (byte == '\\') {
        rpcEscape_ = true;
      } else if (byte == '"') {
        rpcInString_ = false;
      }
      continue;
    }

    if (byte == '"') {
      rpcInString_ = true;
    } else if (byte == '{' || byte == '[') {
      ++rpcDepth_;
    } else if (byte == '}' || byte == ']') {
      --rpcDepth_;
      if (rpcDepth_ == 0) completeRpc();
    }
  }
}

void CodexHidBridge::appendRpcByte(char byte) {
  if (currentRpcLength_ < sizeof(currentRpc_) - 1) {
    currentRpc_[currentRpcLength_++] = byte;
    currentRpc_[currentRpcLength_] = '\0';
  } else {
    currentRpcTruncated_ = true;
  }
}

void CodexHidBridge::completeRpc() {
  if (currentRpcTruncated_) {
    Serial.println(F("CODEX RPC TOO LARGE; DROPPED"));
    resetRpc();
    return;
  }

  Serial.print(F("CODEX "));
  Serial.println(currentRpc_);

  char method[24]{};
  long requestId = 0;
  if (!extractTopLevelMethod(currentRpc_, method, sizeof(method))) {
    resetRpc();
    return;
  }

  if (extractTopLevelRequestId(currentRpc_, &requestId)) {
    char response[192]{};
    if (strcmp(method, "device.status") == 0) {
      snprintf(response, sizeof(response),
               "{\"id\":%ld,\"result\":{\"version\":\"%s-m5\","
               "\"profile_index\":0,\"layer_index\":0,\"battery\":100,"
               "\"is_charging\":true}}\n",
               requestId, kCodexM5FirmwareVersion);
    } else if (strcmp(method, "v.oai.rgbcfg") == 0 ||
               strcmp(method, "v.oai.thstatus") == 0) {
      snprintf(response, sizeof(response), "{\"id\":%ld,\"result\":true}\n",
               requestId);
    } else {
      snprintf(
          response, sizeof(response),
          "{\"id\":%ld,\"error\":{\"message\":\"Unsupported method\"}}\n",
          requestId);
    }
    sendRpc(response);
  }

  if (onRpc_ != nullptr) onRpc_(currentRpc_);
  resetRpc();
}

void CodexHidBridge::resetRpc() {
  rpcStarted_ = false;
  rpcInString_ = false;
  rpcEscape_ = false;
  rpcDepth_ = 0;
  currentRpcLength_ = 0;
  currentRpc_[0] = '\0';
  currentRpcTruncated_ = false;
}
