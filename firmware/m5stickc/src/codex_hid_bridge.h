#pragma once

#include <stddef.h>
#include <stdint.h>

class BLECharacteristic;
class BLEHIDDevice;
class BLEServer;

class CodexHidBridge {
 public:
  using RpcCallback = void (*)(const char* json);

  void begin(BLEServer* server, RpcCallback onRpc);
  void setConnected(bool connected);
  bool isConnected() const;

  bool sendKey(const char* key, int action, int agent = -1);
  bool press(const char* key, uint32_t durationMs = 60, int agent = -1);

  void receiveOutput(const uint8_t* bytes, size_t length);

 private:
  bool sendRpc(const char* json);
  void consumeRpcBytes(const uint8_t* bytes, size_t length);
  void appendRpcByte(char byte);
  void completeRpc();
  void resetRpc();

  BLEHIDDevice* hidDevice_ = nullptr;
  BLECharacteristic* inputReport_ = nullptr;
  BLECharacteristic* outputReport_ = nullptr;
  RpcCallback onRpc_ = nullptr;
  bool connected_ = false;
  bool rpcStarted_ = false;
  bool rpcInString_ = false;
  bool rpcEscape_ = false;
  int16_t rpcDepth_ = 0;
  char currentRpc_[1024]{};
  size_t currentRpcLength_ = 0;
  bool currentRpcTruncated_ = false;
};
