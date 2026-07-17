#include <Arduino.h>
#include <PluggableUSB.h>
#include <USBAPI.h>
#include <USBCore.h>
#include <avr/pgmspace.h>

namespace {

constexpr uint8_t kReportId = 6;
constexpr uint8_t kRpcChannel = 2;
constexpr uint8_t kReportBytes = 64;
constexpr uint8_t kPayloadBytes = 61;
constexpr uint8_t kHidGetReport = 0x01;
constexpr uint8_t kHidGetIdle = 0x02;
constexpr uint8_t kHidGetProtocol = 0x03;
constexpr uint8_t kHidSetReport = 0x09;
constexpr uint8_t kHidSetIdle = 0x0a;
constexpr uint8_t kHidSetProtocol = 0x0b;
constexpr uint8_t kHidReportDescriptorType = 0x22;

template <typename T>
constexpr T smaller(T left, T right) {
  return left < right ? left : right;
}

const uint8_t kReportDescriptor[] PROGMEM = {
    0x06, 0x00, 0xff,  // Usage Page (Vendor 0xff00)
    0x09, 0x01,        // Usage 1
    0xa1, 0x01,        // Collection (Application)
    0x85, 0x06,        // Report ID 6
    0x15, 0x00,        // Logical minimum 0
    0x26, 0xff, 0x00,  // Logical maximum 255
    0x75, 0x08,        // Report size 8
    0x95, 0x3f,        // Report count 63
    0x09, 0x01,
    0x81, 0x02,        // Input (Data, Variable, Absolute)
    0x09, 0x01,
    0x91, 0x02,        // Output (Data, Variable, Absolute)
    0xc0,              // End collection
};

struct HidClassDescriptor {
  uint8_t length;
  uint8_t descriptorType;
  uint16_t hidVersion;
  uint8_t countryCode;
  uint8_t descriptorCount;
  uint8_t reportDescriptorType;
  uint16_t reportDescriptorLength;
} __attribute__((packed));

struct CodexHidInterfaceDescriptor {
  InterfaceDescriptor interface;
  HidClassDescriptor hid;
  EndpointDescriptor input;
  EndpointDescriptor output;
} __attribute__((packed));

class CodexMicroHid final : public PluggableUSBModule {
 public:
  CodexMicroHid() : PluggableUSBModule(2, 1, endpointTypes_) {
    endpointTypes_[0] = EP_TYPE_INTERRUPT_IN;
    endpointTypes_[1] = EP_TYPE_INTERRUPT_OUT;
    PluggableUSB().plug(this);
  }

  void poll();
  bool sendRpc(const char* json);
  void replayFeedback();

 protected:
  int getInterface(uint8_t* interfaceCount) override;
  int getDescriptor(USBSetup& setup) override;
  bool setup(USBSetup& setup) override;
  uint8_t getShortName(char* name) override;

 private:
  void receiveReport(const uint8_t* bytes, uint8_t length);
  void consumeRpcBytes(const uint8_t* bytes, uint8_t length);
  void appendRpcByte(char byte);
  void appendScanByte(char byte);
  void extractFields();
  void completeRpc();
  void resetRpc();

  uint8_t endpointTypes_[2]{};
  uint8_t protocol_ = 1;
  uint8_t idle_ = 1;

  bool rpcStarted_ = false;
  bool rpcInString_ = false;
  bool rpcEscape_ = false;
  int16_t rpcDepth_ = 0;
  char scan_[112]{};
  uint8_t scanLength_ = 0;
  char method_[24]{};
  long requestId_ = 0;
  bool hasRequestId_ = false;
  char currentRpc_[512]{};
  uint16_t currentRpcLength_ = 0;
  bool currentRpcTruncated_ = false;
  char cachedThreadRpc_[512]{};
  uint16_t cachedThreadRpcLength_ = 0;
  char cachedLightingRpc_[256]{};
  uint16_t cachedLightingRpcLength_ = 0;
};

CodexMicroHid codexHid;

int CodexMicroHid::getInterface(uint8_t* interfaceCount) {
  *interfaceCount += 1;
  const CodexHidInterfaceDescriptor descriptor = {
      D_INTERFACE(pluggedInterface, 2, USB_DEVICE_CLASS_HUMAN_INTERFACE, 0, 0),
      {9, 0x21, 0x0111, 0, 1, kHidReportDescriptorType,
       sizeof(kReportDescriptor)},
      D_ENDPOINT(USB_ENDPOINT_IN(pluggedEndpoint), USB_ENDPOINT_TYPE_INTERRUPT,
                 kReportBytes, 1),
      D_ENDPOINT(USB_ENDPOINT_OUT(pluggedEndpoint + 1),
                 USB_ENDPOINT_TYPE_INTERRUPT, kReportBytes, 1),
  };
  return USB_SendControl(0, &descriptor, sizeof(descriptor));
}

int CodexMicroHid::getDescriptor(USBSetup& setup) {
  if (setup.bmRequestType != REQUEST_DEVICETOHOST_STANDARD_INTERFACE ||
      setup.wValueH != kHidReportDescriptorType ||
      setup.wIndex != pluggedInterface) {
    return 0;
  }
  protocol_ = 1;
  return USB_SendControl(TRANSFER_PGM, kReportDescriptor,
                         sizeof(kReportDescriptor));
}

bool CodexMicroHid::setup(USBSetup& setup) {
  if (setup.wIndex != pluggedInterface) return false;

  if (setup.bmRequestType == REQUEST_DEVICETOHOST_CLASS_INTERFACE) {
    if (setup.bRequest == kHidGetProtocol) {
      return USB_SendControl(0, &protocol_, 1) == 1;
    }
    if (setup.bRequest == kHidGetIdle) {
      return USB_SendControl(0, &idle_, 1) == 1;
    }
    if (setup.bRequest == kHidGetReport) return true;
  }

  if (setup.bmRequestType == REQUEST_HOSTTODEVICE_CLASS_INTERFACE) {
    if (setup.bRequest == kHidSetProtocol) {
      protocol_ = setup.wValueL;
      return true;
    }
    if (setup.bRequest == kHidSetIdle) {
      idle_ = setup.wValueL;
      return true;
    }
    if (setup.bRequest == kHidSetReport) {
      uint8_t report[kReportBytes]{};
      const uint16_t wanted =
          smaller<uint16_t>(setup.wLength, sizeof(report));
      const int received = USB_RecvControl(report, wanted);
      if (received > 0) receiveReport(report, static_cast<uint8_t>(received));
      return true;
    }
  }
  return false;
}

uint8_t CodexMicroHid::getShortName(char* name) {
  memcpy(name, "CDXMICRO", 8);
  return 8;
}

void CodexMicroHid::poll() {
  const uint8_t outputEndpoint = pluggedEndpoint + 1;
  const uint8_t available = USB_Available(outputEndpoint);
  if (!available) return;

  uint8_t report[kReportBytes]{};
  const int received = USB_Recv(outputEndpoint, report, sizeof(report));
  if (received > 0) receiveReport(report, static_cast<uint8_t>(received));
}

void CodexMicroHid::receiveReport(const uint8_t* bytes, uint8_t length) {
  if (!length) return;

  if (bytes[0] == kReportId) {
    ++bytes;
    --length;
  }
  if (length < 2 || bytes[0] != kRpcChannel) return;

  const uint8_t payloadLength = smaller<uint8_t>(bytes[1], kPayloadBytes);
  if (length < static_cast<uint8_t>(payloadLength + 2)) return;
  consumeRpcBytes(bytes + 2, payloadLength);
}

void CodexMicroHid::consumeRpcBytes(const uint8_t* bytes, uint8_t length) {
  for (uint8_t index = 0; index < length; ++index) {
    const char byte = static_cast<char>(bytes[index]);
    if (byte == '\0') continue;
    appendScanByte(byte);
    extractFields();

    if (!rpcStarted_) {
      if (byte != '{') continue;
      currentRpcLength_ = 0;
      currentRpcTruncated_ = false;
      appendRpcByte(byte);
      Serial.print(F("FEEDBACK "));
      Serial.write(byte);
      rpcStarted_ = true;
      rpcDepth_ = 1;
      continue;
    }

    appendRpcByte(byte);
    Serial.write(byte);

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
      if (rpcDepth_ == 0) {
        Serial.println();
        completeRpc();
      }
    }
  }
}

void CodexMicroHid::appendRpcByte(char byte) {
  if (currentRpcLength_ < sizeof(currentRpc_) - 1) {
    currentRpc_[currentRpcLength_++] = byte;
    currentRpc_[currentRpcLength_] = '\0';
  } else {
    currentRpcTruncated_ = true;
  }
}

void CodexMicroHid::appendScanByte(char byte) {
  if (scanLength_ == sizeof(scan_) - 1) {
    constexpr uint8_t keep = 64;
    memmove(scan_, scan_ + scanLength_ - keep, keep);
    scanLength_ = keep;
  }
  scan_[scanLength_++] = byte;
  scan_[scanLength_] = '\0';
}

void CodexMicroHid::extractFields() {
  if (!method_[0]) {
    const char* field = strstr(scan_, "\"method\"");
    if (field) {
      const char* colon = strchr(field + 8, ':');
      const char* start = colon ? strchr(colon, '"') : nullptr;
      const char* end = start ? strchr(start + 1, '"') : nullptr;
      if (start && end) {
        const size_t length =
            smaller<size_t>(end - start - 1, sizeof(method_) - 1);
        memcpy(method_, start + 1, length);
        method_[length] = '\0';
      }
    }
  }

  const char* field = scan_;
  const char* latest = nullptr;
  while ((field = strstr(field, "\"id\"")) != nullptr) {
    latest = field;
    field += 4;
  }
  if (!latest) return;

  const char* value = strchr(latest + 4, ':');
  if (!value) return;
  ++value;
  while (*value == ' ' || *value == '\t') ++value;
  if (*value == '-' || (*value >= '0' && *value <= '9')) {
    requestId_ = strtol(value, nullptr, 10);
    hasRequestId_ = true;
  }
}

void CodexMicroHid::completeRpc() {
  digitalWrite(LED_BUILTIN, HIGH);

  if (strcmp(method_, "v.oai.thstatus") == 0 && !currentRpcTruncated_) {
    memcpy(cachedThreadRpc_, currentRpc_, currentRpcLength_ + 1);
    cachedThreadRpcLength_ = currentRpcLength_;
  } else if (strcmp(method_, "v.oai.rgbcfg") == 0 &&
             !currentRpcTruncated_ &&
             currentRpcLength_ < sizeof(cachedLightingRpc_)) {
    memcpy(cachedLightingRpc_, currentRpc_, currentRpcLength_ + 1);
    cachedLightingRpcLength_ = currentRpcLength_;
  }

  char response[192]{};
  if (!hasRequestId_ || !method_[0]) {
    resetRpc();
    return;
  }

  if (strcmp(method_, "device.status") == 0) {
    snprintf_P(
        response, sizeof(response),
        PSTR("{\"id\":%ld,\"result\":{\"version\":\"0.4.0-hw\","
             "\"profile_index\":0,\"layer_index\":0,\"battery\":100,"
             "\"is_charging\":true}}\n"),
        requestId_);
  } else if (strcmp(method_, "v.oai.rgbcfg") == 0 ||
             strcmp(method_, "v.oai.thstatus") == 0) {
    snprintf_P(response, sizeof(response),
               PSTR("{\"id\":%ld,\"result\":true}\n"), requestId_);
  } else {
    snprintf_P(response, sizeof(response),
               PSTR("{\"id\":%ld,\"error\":{\"message\":\"Unsupported method\"}}\n"),
               requestId_);
  }

  sendRpc(response);
  resetRpc();
  digitalWrite(LED_BUILTIN, LOW);
}

void CodexMicroHid::replayFeedback() {
  if (!cachedThreadRpcLength_ && !cachedLightingRpcLength_) {
    Serial.println(F("STATE EMPTY"));
    return;
  }
  if (cachedThreadRpcLength_) {
    Serial.print(F("FEEDBACK "));
    Serial.write(
        reinterpret_cast<const uint8_t*>(cachedThreadRpc_),
        cachedThreadRpcLength_);
    Serial.println();
  }
  if (cachedLightingRpcLength_) {
    Serial.print(F("FEEDBACK "));
    Serial.write(
        reinterpret_cast<const uint8_t*>(cachedLightingRpc_),
        cachedLightingRpcLength_);
    Serial.println();
  }
}

void CodexMicroHid::resetRpc() {
  rpcStarted_ = false;
  rpcInString_ = false;
  rpcEscape_ = false;
  rpcDepth_ = 0;
  scanLength_ = 0;
  scan_[0] = '\0';
  method_[0] = '\0';
  requestId_ = 0;
  hasRequestId_ = false;
  currentRpcLength_ = 0;
  currentRpc_[0] = '\0';
  currentRpcTruncated_ = false;
}

bool CodexMicroHid::sendRpc(const char* json) {
  const size_t length = strlen(json);
  for (size_t offset = 0; offset < length; offset += kPayloadBytes) {
    const uint8_t chunk = smaller<size_t>(kPayloadBytes, length - offset);
    uint8_t report[kReportBytes]{};
    report[0] = kReportId;
    report[1] = kRpcChannel;
    report[2] = chunk;
    memcpy(report + 3, json + offset, chunk);
    if (USB_Send(pluggedEndpoint | TRANSFER_RELEASE, report,
                 sizeof(report)) < 0) {
      return false;
    }
  }
  return true;
}

char serialLine[80]{};
uint8_t serialLength = 0;

bool validKey(const char* key) {
  if (!key || !*key) return false;
  for (const char* cursor = key; *cursor; ++cursor) {
    if (!((*cursor >= 'A' && *cursor <= 'Z') ||
          (*cursor >= '0' && *cursor <= '9') || *cursor == '_')) {
      return false;
    }
  }
  return true;
}

void emitHid(const char* key, int action, const char* agent = nullptr) {
  if (!validKey(key) || action < 0 || action > 2) return;
  char message[112]{};
  if (agent && *agent) {
    snprintf_P(message, sizeof(message),
               PSTR("{\"method\":\"v.oai.hid\",\"params\":{\"k\":\"%s\","
                    "\"act\":%d,\"ag\":%s}}\n"),
               key, action, agent);
  } else {
    snprintf_P(message, sizeof(message),
               PSTR("{\"method\":\"v.oai.hid\",\"params\":{\"k\":\"%s\","
                    "\"act\":%d}}\n"),
               key, action);
  }
  codexHid.sendRpc(message);
}

void processSerialLine(char* line) {
  char* command = strtok(line, " \t");
  if (!command) return;

  if (strcmp(command, "HID") == 0) {
    const char* key = strtok(nullptr, " \t");
    const char* actionText = strtok(nullptr, " \t");
    const char* agent = strtok(nullptr, " \t");
    if (key && actionText) emitHid(key, atoi(actionText), agent);
    return;
  }

  if (strcmp(command, "RAD") == 0) {
    const char* angle = strtok(nullptr, " \t");
    const char* distance = strtok(nullptr, " \t");
    if (!angle || !distance) return;
    char message[112]{};
    snprintf_P(message, sizeof(message),
               PSTR("{\"method\":\"v.oai.rad\",\"params\":{\"a\":%s,\"d\":%s}}\n"),
               angle, distance);
    codexHid.sendRpc(message);
    return;
  }

  if (strcmp(command, "PING") == 0) {
    Serial.println(F("READY Codex Micro Bridge 0.4.0-hw"));
  } else if (strcmp(command, "REPLAY") == 0) {
    codexHid.replayFeedback();
  }
}

void pollSerial() {
  while (Serial.available()) {
    const char byte = static_cast<char>(Serial.read());
    if (byte == '\r') continue;
    if (byte == '\n') {
      serialLine[serialLength] = '\0';
      processSerialLine(serialLine);
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

}  // namespace

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, LOW);
  Serial.begin(115200);
}

void loop() {
  codexHid.poll();
  pollSerial();
}
