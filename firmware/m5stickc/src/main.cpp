#include <Arduino.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <M5Unified.h>

namespace {

constexpr char kServiceUuid[] = "7A0A0001-1E8E-4D91-9A4B-21D02E0C0D01";
constexpr char kNotifyUuid[] = "7A0A0002-1E8E-4D91-9A4B-21D02E0C0D01";
constexpr char kWriteUuid[] = "7A0A0003-1E8E-4D91-9A4B-21D02E0C0D01";
constexpr uint8_t kAgentCount = 6;
constexpr uint32_t kMicSampleRate = 16000;
constexpr size_t kMicSamples = 160;

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
  char text[24];
};

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
char displayedLabel[12] = "OFFLINE";
BLECharacteristic* notifyCharacteristic = nullptr;
QueueHandle_t commandQueue = nullptr;
volatile bool bleConnected = false;
volatile bool announceReady = false;
volatile bool hasCodexState = false;
volatile bool screenDirty = true;

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
    for (uint8_t index = 0; index < kAgentCount; ++index) {
      const int priority = statePriority(agents[index]);
      if (priority > selectedPriority) {
        selectedPriority = priority;
        selectedAgent = index;
      }
      if (isActive(agents[index])) ++activeCount;
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
    emitLine("READY M5 0.3");
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
    voiceState = parseVoiceState(line + 6);
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

void emitButtons() {
  if (M5.BtnA.wasPressed()) emitLine("BUTTON A DOWN");
  if (M5.BtnA.wasReleased()) emitLine("BUTTON A UP");
  if (M5.BtnB.wasPressed()) emitLine("BUTTON B DOWN");
  if (M5.BtnB.wasReleased()) emitLine("BUTTON B UP");
  if (M5.BtnPWR.wasPressed()) emitLine("BUTTON POWER DOWN");
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
  void onConnect(BLEServer*) override {
    bleConnected = true;
    hasCodexState = false;
    voiceState = VoiceState::Idle;
    speechState = SpeechState::Idle;
    screenDirty = true;
    announceReady = true;
  }

  void onDisconnect(BLEServer*) override {
    bleConnected = false;
    hasCodexState = false;
    voiceState = VoiceState::Idle;
    speechState = SpeechState::Idle;
    screenDirty = true;
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
  BLEDevice::init("Codex M5");
  BLEDevice::setMTU(64);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService* service = server->createService(kServiceUuid);
  notifyCharacteristic = service->createCharacteristic(
      kNotifyUuid, BLECharacteristic::PROPERTY_NOTIFY);
  notifyCharacteristic->addDescriptor(new BLE2902());
  BLECharacteristic* writeCharacteristic = service->createCharacteristic(
      kWriteUuid,
      BLECharacteristic::PROPERTY_WRITE |
          BLECharacteristic::PROPERTY_WRITE_NR);
  writeCharacteristic->setCallbacks(new CommandCallbacks());
  service->start();

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(kServiceUuid);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();
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
  Serial.println(F("READY M5 0.3"));
}

void loop() {
  M5.update();
  pollSerial();
  pollBleCommands();
  if (screenDirty) {
    screenDirty = false;
    drawDashboard();
  }
  if (announceReady) {
    announceReady = false;
    emitLine("READY M5 0.3");
  }
  emitButtons();
  pollMicrophone();
  delay(1);
}
