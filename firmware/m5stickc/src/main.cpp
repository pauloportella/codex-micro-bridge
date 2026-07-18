#include <Arduino.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLESecurity.h>
#include <BLEServer.h>
#include <M5Unified.h>

#include "codex_hid_bridge.h"
#include "codex_rpc_protocol.h"
#include "firmware_version.h"
#include "ride_bridge.h"
#include "voice_button_controller.h"

namespace {

constexpr char kServiceUuid[] = "7A0A0001-1E8E-4D91-9A4B-21D02E0C0D01";
constexpr char kNotifyUuid[] = "7A0A0002-1E8E-4D91-9A4B-21D02E0C0D01";
constexpr char kWriteUuid[] = "7A0A0003-1E8E-4D91-9A4B-21D02E0C0D01";
constexpr uint8_t kAgentCount = 6;
constexpr uint32_t kMicSampleRate = 16000;
constexpr size_t kMicSamples = 160;
constexpr uint32_t kDoneDisplayMs = 2000;
constexpr uint32_t kVoiceProcessingTimeoutMs = 60000;
constexpr size_t kRpcMessageBytes = 1024;

enum class AgentState : uint8_t {
  Off,
  Idle,
  Unread,
  Thinking,
  NeedsInput,
  Error,
};

enum class VoiceState : uint8_t {
  Idle,
  Recording,
  Processing,
  Completed,
};

enum class SpeechState : uint8_t {
  Idle,
  Preparing,
  Speaking,
};

struct CommandMessage {
  char text[48];
};

struct RpcMessage {
  char text[kRpcMessageBytes];
};

CodexHidBridge codexHid;
RideBridge rideBridge;
VoiceButtonController voiceButton;
AgentState agents[kAgentCount]{};
VoiceState voiceState = VoiceState::Idle;
SpeechState speechState = SpeechState::Idle;
char serialLine[192]{};
size_t serialLength = 0;
int16_t micBuffers[3][kMicSamples]{};
uint8_t micRecordIndex = 2;
int micLevel = 0;
int lastSentMicLevel = -1;
uint32_t lastMicReportMs = 0;
uint32_t doneUntilMs = 0;
uint8_t unreadMask = 0;
char displayedLabel[12] = "OFFLINE";
BLECharacteristic* notifyCharacteristic = nullptr;
BLE2902* companionNotifyDescriptor = nullptr;
QueueHandle_t commandQueue = nullptr;
QueueHandle_t rpcQueue = nullptr;
volatile bool bleConnected = false;
volatile bool announceReady = false;
volatile bool hasCodexState = false;
volatile bool screenDirty = true;
volatile bool voiceSubmitPending = false;
volatile uint32_t voiceCompletedAtMs = 0;
uint32_t voiceStateChangedAtMs = 0;
bool voiceFeedbackObserved = false;
volatile uint32_t droppedRpcMessages = 0;

bool companionModeActive() {
  return companionNotifyDescriptor != nullptr &&
         companionNotifyDescriptor->getNotifications();
}

void resetVoiceState() {
  voiceState = VoiceState::Idle;
  voiceButton.observedIdle();
  voiceSubmitPending = false;
  voiceFeedbackObserved = false;
  voiceStateChangedAtMs = millis();
  screenDirty = true;
}

void setVoiceState(VoiceState state, bool feedbackObserved) {
  voiceState = state;
  voiceFeedbackObserved = feedbackObserved;
  voiceStateChangedAtMs = millis();
  screenDirty = true;
}

uint16_t rgb(uint32_t color) {
  return M5.Display.color565(
      static_cast<uint8_t>(color >> 16),
      static_cast<uint8_t>(color >> 8),
      static_cast<uint8_t>(color));
}

uint16_t stateColor(AgentState state) {
  switch (state) {
    case AgentState::Thinking:
      return rgb(0x304FFE);
    case AgentState::Unread:
      return rgb(0x00FF4C);
    case AgentState::Idle:
      return rgb(0xFFFFFF);
    case AgentState::NeedsInput:
      return rgb(0xFF6D00);
    case AgentState::Error:
      return rgb(0xFF0033);
    case AgentState::Off:
    default:
      return rgb(0x20242C);
  }
}

const char* stateLabel(AgentState state) {
  switch (state) {
    case AgentState::Thinking:
      return "THINKING";
    case AgentState::Unread:
      return "DONE";
    case AgentState::Idle:
      return "IDLE";
    case AgentState::NeedsInput:
      return "NEEDS YOU";
    case AgentState::Error:
      return "ERROR";
    case AgentState::Off:
    default:
      return "OFFLINE";
  }
}

uint16_t voiceColor(VoiceState state) {
  switch (state) {
    case VoiceState::Recording:
      return rgb(0x2E8B57);
    case VoiceState::Processing:
    case VoiceState::Completed:
      return rgb(0xFFFFFF);
    case VoiceState::Idle:
    default:
      return rgb(0x20242C);
  }
}

const char* voiceLabel(VoiceState state) {
  switch (state) {
    case VoiceState::Recording:
      return "LISTENING";
    case VoiceState::Processing:
      return "PROCESSING";
    case VoiceState::Completed:
      return "HEARD";
    case VoiceState::Idle:
    default:
      return "IDLE";
  }
}

VoiceState parseVoiceState(const char* value) {
  if (strcmp(value, "RECORDING") == 0) return VoiceState::Recording;
  if (strcmp(value, "PROCESSING") == 0) return VoiceState::Processing;
  if (strcmp(value, "COMPLETED") == 0) return VoiceState::Completed;
  return VoiceState::Idle;
}

int statePriority(AgentState state) {
  switch (state) {
    case AgentState::Error:
      return 5;
    case AgentState::NeedsInput:
      return 4;
    case AgentState::Thinking:
      return 3;
    case AgentState::Unread:
      return 2;
    case AgentState::Idle:
      return 1;
    case AgentState::Off:
    default:
      return 0;
  }
}

bool isActive(AgentState state) {
  return state != AgentState::Off && state != AgentState::Idle;
}

AgentState parseState(const char* value) {
  if (strcmp(value, "IDLE") == 0) return AgentState::Idle;
  if (strcmp(value, "UNREAD") == 0) return AgentState::Unread;
  if (strcmp(value, "THINKING") == 0) return AgentState::Thinking;
  if (strcmp(value, "NEEDS_INPUT") == 0) return AgentState::NeedsInput;
  if (strcmp(value, "ERROR") == 0) return AgentState::Error;
  return AgentState::Off;
}

bool extractJsonLong(const char* start, const char* end, const char* field,
                     long* value) {
  const char* found = strstr(start, field);
  if (found == nullptr || found >= end) return false;
  const char* colon = strchr(found + strlen(field), ':');
  if (colon == nullptr || colon >= end) return false;
  *value = strtol(colon + 1, nullptr, 10);
  return true;
}

bool extractJsonDouble(const char* start, const char* end, const char* field,
                       double* value) {
  const char* found = strstr(start, field);
  if (found == nullptr || found >= end) return false;
  const char* colon = strchr(found + strlen(field), ':');
  if (colon == nullptr || colon >= end) return false;
  *value = strtod(colon + 1, nullptr);
  return true;
}

AgentState stateForColor(long color, double brightness) {
  if (brightness <= 0 || color == 0) return AgentState::Off;
  switch (color) {
    case 0x304FFE:
      return AgentState::Thinking;
    case 0x00FF4C:
      return AgentState::Unread;
    case 0xFFFFFF:
      return AgentState::Idle;
    case 0xFF6D00:
      return AgentState::NeedsInput;
    case 0xFF0033:
      return AgentState::Error;
    default:
      return AgentState::Off;
  }
}

void processThreadStatus(const char* json) {
  const char* params = strstr(json, "\"params\"");
  const char* cursor = params == nullptr ? nullptr : strchr(params, '[');
  if (cursor == nullptr) return;
  const char* paramsEnd = strchr(cursor, ']');
  if (paramsEnd == nullptr) return;
  ++cursor;
  AgentState nextAgents[kAgentCount]{};
  bool decodedAny = false;
  while ((cursor = strchr(cursor, '{')) != nullptr && cursor < paramsEnd) {
    const char* end = strchr(cursor, '}');
    if (end == nullptr || end > paramsEnd) return;
    long id = -1;
    long color = 0;
    double brightness = 1;
    if (extractJsonLong(cursor, end, "\"id\"", &id) &&
        extractJsonLong(cursor, end, "\"c\"", &color) && id >= 0 &&
        id < kAgentCount) {
      extractJsonDouble(cursor, end, "\"b\"", &brightness);
      nextAgents[id] = stateForColor(color, brightness);
      decodedAny = true;
    }
    cursor = end + 1;
  }
  if (decodedAny) {
    memcpy(agents, nextAgents, sizeof(agents));
    uint8_t currentUnreadMask = 0;
    for (uint8_t index = 0; index < kAgentCount; ++index) {
      if (agents[index] == AgentState::Unread) {
        currentUnreadMask |= static_cast<uint8_t>(1U << index);
      }
    }
    if ((currentUnreadMask & ~unreadMask) != 0) {
      doneUntilMs = millis() + kDoneDisplayMs;
    }
    unreadMask = currentUnreadMask;
    hasCodexState = true;
    screenDirty = true;
  }
}

void processLightingStatus(const char* json) {
  const char* ambient = strstr(json, "\"ambient\"");
  const char* start = ambient == nullptr ? nullptr : strchr(ambient, '{');
  const char* end = start == nullptr ? nullptr : strchr(start, '}');
  if (start == nullptr || end == nullptr) return;
  long effect = 0;
  long color = 0;
  double brightness = 1;
  if (!extractJsonLong(start, end, "\"e\"", &effect) ||
      !extractJsonLong(start, end, "\"c\"", &color)) {
    return;
  }
  extractJsonDouble(start, end, "\"b\"", &brightness);

  if (brightness > 0 && effect == 2 && color == 0x2E8B57) {
    if (voiceButton.observedRecording()) {
      setVoiceState(VoiceState::Recording, true);
    }
  } else if (brightness > 0 && effect == 2 && color == 0xFFFFFF) {
    voiceButton.observedProcessing();
    setVoiceState(VoiceState::Processing, true);
  } else if (brightness > 0 && effect == 1 && color == 0xFFFFFF &&
             (voiceState == VoiceState::Recording ||
              voiceState == VoiceState::Processing)) {
    voiceButton.observedCompleted();
    setVoiceState(VoiceState::Completed, true);
    voiceSubmitPending = true;
    voiceCompletedAtMs = millis();
  } else if (voiceFeedbackObserved &&
             (voiceState == VoiceState::Recording ||
              voiceState == VoiceState::Processing)) {
    Serial.println(F("CODEX VOICE RETURNED TO IDLE"));
    resetVoiceState();
  }
}

void processCodexRpc(const char* json) {
  if (companionModeActive()) return;
  char method[24]{};
  if (!extractTopLevelMethod(json, method, sizeof(method))) return;
  if (strcmp(method, "v.oai.thstatus") == 0) {
    processThreadStatus(json);
  } else if (strcmp(method, "v.oai.rgbcfg") == 0) {
    processLightingStatus(json);
  } else if (strcmp(method, "v.m5.ride") == 0) {
    if (strstr(json, "\"command\":\"status\"") != nullptr) {
      rideBridge.reportStatus();
    } else if (strstr(json, "\"command\":\"mute\"") != nullptr) {
      rideBridge.setHidMuted(true);
    } else if (strstr(json, "\"command\":\"unmute\"") != nullptr) {
      rideBridge.setHidMuted(false);
    } else if (strstr(json, "\"command\":\"stop\"") != nullptr) {
      rideBridge.stopScan();
    } else if (strstr(json, "\"command\":\"scan\"") != nullptr) {
      long seconds = 60;
      extractJsonLong(json, json + strlen(json), "\"seconds\"", &seconds);
      seconds = constrain(seconds, 1L, 300L);
      rideBridge.scanFor(static_cast<uint32_t>(seconds) * 1000);
    }
  }
}

void enqueueCodexRpc(const char* json) {
  if (json == nullptr || rpcQueue == nullptr) return;
  RpcMessage message{};
  const size_t length = strnlen(json, sizeof(message.text));
  if (length >= sizeof(message.text)) {
    ++droppedRpcMessages;
    return;
  }
  memcpy(message.text, json, length + 1);
  if (xQueueSend(rpcQueue, &message, 0) == pdTRUE) return;

  RpcMessage discarded{};
  xQueueReceive(rpcQueue, &discarded, 0);
  if (xQueueSend(rpcQueue, &message, 0) != pdTRUE) ++droppedRpcMessages;
}

void drawMicMeter() {
  constexpr int x = 185;
  constexpr int y = 120;
  constexpr int width = 49;
  constexpr int height = 8;
  M5.Display.fillRect(x, y, width, height, rgb(0x20242C));
  M5.Display.fillRect(x, y, width * micLevel / 100, height, rgb(0x00FF4C));
}

void drawDashboard() {
  int selectedAgent = -1;
  int selectedPriority = -1;
  int activeCount = 0;
  AgentState state = AgentState::Off;
  const char* label = "OFFLINE";
  const bool voiceOverride = bleConnected && voiceState != VoiceState::Idle;
  const bool speechOverride =
      bleConnected && speechState != SpeechState::Idle && !voiceOverride;

  if (voiceOverride) {
    label = voiceLabel(voiceState);
  } else if (speechOverride) {
    label = speechState == SpeechState::Preparing ? "PREPARING" : "SPEAKING";
  } else if (bleConnected && !hasCodexState) {
    label = "WAITING";
  } else if (bleConnected) {
    const bool showDone =
        doneUntilMs != 0 && static_cast<int32_t>(doneUntilMs - millis()) > 0;
    for (uint8_t index = 0; index < kAgentCount; ++index) {
      const AgentState agentState = agents[index];
      const int priority =
          agentState == AgentState::Unread && !showDone ? 0
                                                       : statePriority(agentState);
      if (priority > selectedPriority) {
        selectedPriority = priority;
        selectedAgent = index;
      }
      if (isActive(agentState) &&
          (agentState != AgentState::Unread || showDone)) {
        ++activeCount;
      }
    }
    if (selectedPriority == 0) {
      selectedAgent = -1;
      state = AgentState::Idle;
    } else {
      state = agents[selectedAgent];
    }
    label = stateLabel(state);
  }

  const uint16_t color = voiceOverride
                             ? voiceColor(voiceState)
                             : (speechOverride
                                    ? rgb(speechState == SpeechState::Preparing
                                              ? 0x5E35B1
                                              : 0x7C4DFF)
                                    : stateColor(state));
  strncpy(displayedLabel, label, sizeof(displayedLabel) - 1);
  displayedLabel[sizeof(displayedLabel) - 1] = '\0';
  const uint16_t textColor = voiceOverride
                                 ? (voiceState == VoiceState::Recording ? TFT_WHITE
                                                                        : TFT_BLACK)
                                 : (state == AgentState::Unread ||
                                            state == AgentState::Idle ||
                                            state == AgentState::NeedsInput
                                        ? TFT_BLACK
                                        : TFT_WHITE);

  M5.Display.startWrite();
  M5.Display.fillRect(0, 0, 240, 111, color);
  M5.Display.setTextColor(textColor, color);
  M5.Display.setTextSize(1);
  M5.Display.setTextDatum(top_left);
  if (!voiceOverride && !speechOverride && selectedAgent >= 0) {
    M5.Display.setCursor(7, 7);
    M5.Display.printf("A%d", selectedAgent + 1);
  }
  if (!voiceOverride && !speechOverride && activeCount > 1) {
    M5.Display.setTextDatum(top_right);
    M5.Display.drawString(String("+") + String(activeCount - 1), 233, 7);
  }
  M5.Display.setTextDatum(middle_center);
  M5.Display.setTextSize(3);
  M5.Display.drawString(label, 120, 57);

  M5.Display.fillRect(0, 111, 240, 24, TFT_BLACK);
  M5.Display.setTextColor(TFT_WHITE, TFT_BLACK);
  M5.Display.setTextDatum(middle_left);
  M5.Display.setTextSize(2);
  M5.Display.drawString("CODEX", 7, 123);
  M5.Display.setTextColor(rgb(0xAEB7C5), TFT_BLACK);
  M5.Display.setTextSize(1);
  M5.Display.drawString("MIC", 158, 123);
  drawMicMeter();
  M5.Display.endWrite();
}

void emitLine(const char* line) {
  Serial.println(line);
  if (!bleConnected || notifyCharacteristic == nullptr) return;
  notifyCharacteristic->setValue(
      reinterpret_cast<uint8_t*>(const_cast<char*>(line)), strlen(line));
  notifyCharacteristic->notify();
}

void processCommand(char* line) {
  if (strcmp(line, "PING") == 0) {
    if (companionModeActive()) resetVoiceState();
    char ready[32]{};
    snprintf(ready, sizeof(ready), "READY M5 %s", kCodexM5FirmwareVersion);
    emitLine(ready);
    return;
  }

  if (strncmp(line, "HID ", 4) == 0) {
    char* key = strtok(line + 4, " ");
    char* actionText = strtok(nullptr, " ");
    char* agentText = strtok(nullptr, " ");
    if (key != nullptr && actionText != nullptr) {
      codexHid.sendKey(key, atoi(actionText),
                       agentText == nullptr ? -1 : atoi(agentText));
    }
    return;
  }

  if (strncmp(line, "RIDE", 4) == 0) {
    if (strcmp(line, "RIDE STATUS") == 0) {
      rideBridge.reportStatus();
    } else if (strcmp(line, "RIDE MUTE") == 0) {
      rideBridge.setHidMuted(true);
    } else if (strcmp(line, "RIDE UNMUTE") == 0) {
      rideBridge.setHidMuted(false);
    } else if (strcmp(line, "RIDE STOP") == 0) {
      rideBridge.stopScan();
    } else if (strncmp(line, "RIDE SCAN", 9) == 0) {
      const char* secondsText = line + 9;
      while (*secondsText == ' ') ++secondsText;
      long seconds = *secondsText == '\0' ? 60 : strtol(secondsText, nullptr, 10);
      seconds = constrain(seconds, 1L, 300L);
      rideBridge.scanFor(static_cast<uint32_t>(seconds) * 1000);
    }
    return;
  }

  if (strncmp(line, "STATE ", 6) == 0) {
    char* idText = strtok(line + 6, " ");
    char* stateText = strtok(nullptr, " ");
    if (!idText || !stateText) return;
    const int id = atoi(idText);
    if (id < 0 || id >= kAgentCount) return;
    agents[id] = parseState(stateText);
    hasCodexState = true;
    drawDashboard();
    char acknowledgement[24]{};
    snprintf(
        acknowledgement, sizeof(acknowledgement), "DISPLAY %s",
        displayedLabel);
    emitLine(acknowledgement);
    return;
  }

  if (strncmp(line, "VOICE ", 6) == 0) {
    const VoiceState next = parseVoiceState(line + 6);
    if (next == VoiceState::Idle) {
      resetVoiceState();
    } else {
      setVoiceState(next, true);
    }
    drawDashboard();
    char acknowledgement[24]{};
    snprintf(
        acknowledgement, sizeof(acknowledgement), "DISPLAY %s",
        displayedLabel);
    emitLine(acknowledgement);
    return;
  }

  if (strncmp(line, "SPEECH ", 7) == 0) {
    if (strcmp(line + 7, "PREPARING") == 0) {
      speechState = SpeechState::Preparing;
    } else if (strcmp(line + 7, "SPEAKING") == 0) {
      speechState = SpeechState::Speaking;
    } else {
      speechState = SpeechState::Idle;
    }
    drawDashboard();
    char acknowledgement[24]{};
    snprintf(
        acknowledgement, sizeof(acknowledgement), "DISPLAY %s",
        displayedLabel);
    emitLine(acknowledgement);
    return;
  }
}

void pollSerial() {
  while (Serial.available()) {
    const char byte = static_cast<char>(Serial.read());
    if (byte == '\r') continue;
    if (byte == '\n') {
      serialLine[serialLength] = '\0';
      processCommand(serialLine);
      serialLength = 0;
      continue;
    }
    if (serialLength < sizeof(serialLine) - 1) {
      serialLine[serialLength++] = byte;
    } else {
      serialLength = 0;
    }
  }
}

void pollBleCommands() {
  if (commandQueue == nullptr) return;
  CommandMessage message{};
  while (xQueueReceive(commandQueue, &message, 0) == pdTRUE) {
    processCommand(message.text);
  }
}

void pollCodexRpc() {
  if (rpcQueue == nullptr) return;
  RpcMessage message{};
  while (xQueueReceive(rpcQueue, &message, 0) == pdTRUE) {
    processCodexRpc(message.text);
  }
  if (droppedRpcMessages != 0) {
    const uint32_t dropped = droppedRpcMessages;
    droppedRpcMessages = 0;
    Serial.printf("CODEX RPC QUEUE DROPPED %lu MESSAGE(S)\n",
                  static_cast<unsigned long>(dropped));
  }
}

void emitButtons() {
  if (M5.BtnA.wasPressed()) {
    emitLine("BUTTON A DOWN");
    if (!companionModeActive()) {
      const auto action = voiceButton.nextAction();
      if (action == VoiceButtonController::Action::Start) {
        setVoiceState(VoiceState::Recording, false);
        Serial.println(F("CODEX VOICE BUTTON START ACT10 X2"));
        const bool firstPress = codexHid.press("ACT10");
        delay(60);
        const bool secondPress = codexHid.press("ACT10");
        if (!firstPress || !secondPress) {
          Serial.println(F("CODEX VOICE START FAILED"));
          resetVoiceState();
        }
      } else if (action == VoiceButtonController::Action::Stop) {
        setVoiceState(VoiceState::Processing, false);
        Serial.println(F("CODEX VOICE BUTTON STOP ACT10 X1"));
        if (!codexHid.press("ACT10")) {
          Serial.println(F("CODEX VOICE STOP FAILED"));
          resetVoiceState();
        }
      } else {
        Serial.println(F("CODEX VOICE BUTTON IGNORED DURING TRANSCRIPTION"));
      }
    }
  }
  if (M5.BtnA.wasReleased()) emitLine("BUTTON A UP");
  if (M5.BtnB.wasPressed()) {
    emitLine("BUTTON B DOWN");
    if (!companionModeActive()) codexHid.press("ACT07");
  }
  if (M5.BtnB.wasReleased()) emitLine("BUTTON B UP");
  if (M5.BtnPWR.wasPressed()) {
    emitLine("BUTTON POWER DOWN");
    if (!companionModeActive()) codexHid.press("ACT08");
  }
  if (M5.BtnPWR.wasReleased()) emitLine("BUTTON POWER UP");
}

void pollMicrophone() {
  if (!M5.Mic.isEnabled()) return;
  if (!M5.Mic.record(micBuffers[micRecordIndex], kMicSamples, kMicSampleRate)) return;

  int32_t peak = 0;
  for (size_t index = 0; index < kMicSamples; ++index) {
    int32_t sample = micBuffers[micRecordIndex][index];
    if (sample < 0) sample = -sample;
    if (sample > peak) peak = sample;
  }

  micLevel = constrain(static_cast<int>(peak * 100 / 12000), 0, 100);
  drawMicMeter();

  const uint32_t now = millis();
  if (now - lastMicReportMs >= 250 && abs(micLevel - lastSentMicLevel) >= 5) {
    char report[16]{};
    snprintf(report, sizeof(report), "MIC LEVEL %d", micLevel);
    emitLine(report);
    lastSentMicLevel = micLevel;
    lastMicReportMs = now;
  }

  if (++micRecordIndex >= 3) micRecordIndex = 0;
}

class ServerCallbacks : public BLEServerCallbacks {
 public:
  void onConnect(BLEServer*, esp_ble_gatts_cb_param_t* parameters) override {
    if (parameters != nullptr &&
        rideBridge.isRidePeer(parameters->connect.remote_bda)) {
      Serial.println(F("RIDE BLE PEER CONNECTED"));
      return;
    }
    if (companionNotifyDescriptor != nullptr) {
      companionNotifyDescriptor->setNotifications(false);
    }
    bleConnected = true;
    codexHid.setConnected(true);
    hasCodexState = false;
    unreadMask = 0;
    doneUntilMs = 0;
    voiceState = VoiceState::Idle;
    voiceButton.reset();
    voiceSubmitPending = false;
    speechState = SpeechState::Idle;
    screenDirty = true;
    announceReady = true;
    Serial.println(F("CODEX BLE PEER CONNECTED"));
  }

  void onDisconnect(BLEServer*, esp_ble_gatts_cb_param_t* parameters) override {
    if (parameters != nullptr &&
        rideBridge.isRidePeer(parameters->disconnect.remote_bda)) {
      Serial.println(F("RIDE BLE PEER DISCONNECTED"));
      BLEDevice::startAdvertising();
      return;
    }
    if (companionNotifyDescriptor != nullptr) {
      companionNotifyDescriptor->setNotifications(false);
    }
    bleConnected = false;
    codexHid.setConnected(false);
    hasCodexState = false;
    unreadMask = 0;
    doneUntilMs = 0;
    voiceState = VoiceState::Idle;
    voiceButton.reset();
    voiceSubmitPending = false;
    speechState = SpeechState::Idle;
    screenDirty = true;
    Serial.println(F("CODEX BLE PEER DISCONNECTED"));
    BLEDevice::startAdvertising();
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
 public:
  void onWrite(BLECharacteristic* characteristic) override {
    const std::string value = characteristic->getValue();
    if (value.empty() || commandQueue == nullptr) return;
    CommandMessage message{};
    const size_t length = min(value.length(), sizeof(message.text) - 1);
    memcpy(message.text, value.data(), length);
    xQueueSend(commandQueue, &message, 0);
  }
};

void startBluetooth() {
  commandQueue = xQueueCreate(16, sizeof(CommandMessage));
  rpcQueue = xQueueCreate(4, sizeof(RpcMessage));
  BLEDevice::init("Codex M5");
  BLEDevice::setMTU(128);
  BLEDevice::setEncryptionLevel(ESP_BLE_SEC_ENCRYPT);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService* service = server->createService(kServiceUuid);
  notifyCharacteristic = service->createCharacteristic(
      kNotifyUuid, BLECharacteristic::PROPERTY_NOTIFY);
  companionNotifyDescriptor = new BLE2902();
  notifyCharacteristic->addDescriptor(companionNotifyDescriptor);
  BLECharacteristic* writeCharacteristic = service->createCharacteristic(
      kWriteUuid,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  writeCharacteristic->setCallbacks(new CommandCallbacks());
  service->start();
  codexHid.begin(server, enqueueCodexRpc);

  auto* security = new BLESecurity();
  security->setAuthenticationMode(ESP_LE_AUTH_BOND);
  security->setCapability(ESP_IO_CAP_NONE);
  security->setInitEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(kServiceUuid);
  advertising->addServiceUUID(BLEUUID(static_cast<uint16_t>(0x1812)));
  advertising->setAppearance(0x03c0);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();
  rideBridge.begin(&codexHid, emitLine);
}

}  // namespace

void setup() {
  auto config = M5.config();
  M5.begin(config);
  M5.Display.setRotation(1);
  M5.Display.setBrightness(90);
  Serial.begin(115200);

  M5.Speaker.end();
  M5.Mic.begin();
  drawDashboard();
  startBluetooth();
  Serial.printf("READY M5 %s\n", kCodexM5FirmwareVersion);
}

void loop() {
  M5.update();
  pollSerial();
  pollBleCommands();
  pollCodexRpc();
  rideBridge.poll();
  if (voiceSubmitPending) {
    voiceSubmitPending = false;
    if (codexHid.press("ACT12")) {
      Serial.println(F("CODEX VOICE COMPLETED -> ACT12 SUBMIT"));
    } else {
      Serial.println(F("CODEX VOICE ACT12 SUBMIT FAILED"));
    }
  }
  if (voiceState == VoiceState::Completed &&
      millis() - voiceCompletedAtMs >= 1000) {
    voiceState = VoiceState::Idle;
    voiceButton.observedIdle();
    screenDirty = true;
  }
  const uint32_t voiceElapsedMs = millis() - voiceStateChangedAtMs;
  if (voiceState == VoiceState::Processing &&
      voiceElapsedMs >= kVoiceProcessingTimeoutMs) {
    Serial.println(F("CODEX VOICE PROCESSING TIMEOUT"));
    resetVoiceState();
  }
  if (doneUntilMs != 0 &&
      static_cast<int32_t>(millis() - doneUntilMs) >= 0) {
    doneUntilMs = 0;
    screenDirty = true;
  }
  if (screenDirty) {
    screenDirty = false;
    drawDashboard();
  }
  if (announceReady) {
    announceReady = false;
    char ready[32]{};
    snprintf(ready, sizeof(ready), "READY M5 %s", kCodexM5FirmwareVersion);
    emitLine(ready);
  }
  emitButtons();
  pollMicrophone();
  delay(1);
}
