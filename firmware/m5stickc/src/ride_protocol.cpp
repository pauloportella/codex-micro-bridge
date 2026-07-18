#include "ride_protocol.h"

#include <limits.h>

namespace {

struct DigitalButton {
  RideButton button;
  uint32_t mask;
};

constexpr DigitalButton kDigitalButtons[] = {
    {RideButton::NavigationLeft, 0x00001},
    {RideButton::NavigationUp, 0x00002},
    {RideButton::NavigationRight, 0x00004},
    {RideButton::NavigationDown, 0x00008},
    {RideButton::A, 0x00010},
    {RideButton::B, 0x00020},
    {RideButton::Y, 0x00040},
    {RideButton::Z, 0x00080},
    {RideButton::ShiftUpLeft, 0x00100},
    {RideButton::ShiftDownLeft, 0x00200},
    {RideButton::PowerUpLeft, 0x00400},
    {RideButton::OnOffLeft, 0x00800},
    {RideButton::ShiftUpRight, 0x01000},
    {RideButton::ShiftDownRight, 0x02000},
    {RideButton::PowerUpRight, 0x04000},
    {RideButton::OnOffRight, 0x08000},
};

bool readVarint(const uint8_t* bytes, size_t length, size_t* index,
                uint64_t* value) {
  uint64_t decoded = 0;
  uint8_t shift = 0;
  while (*index < length && shift < 64) {
    const uint8_t byte = bytes[(*index)++];
    if (shift == 63 && (byte & 0x7e) != 0) return false;
    decoded |= static_cast<uint64_t>(byte & 0x7f) << shift;
    if ((byte & 0x80) == 0) {
      *value = decoded;
      return true;
    }
    shift += 7;
  }
  return false;
}

bool skipField(uint64_t wireType, const uint8_t* bytes, size_t length,
               size_t* index) {
  uint64_t fieldLength = 0;
  switch (wireType) {
    case 0:
      return readVarint(bytes, length, index, &fieldLength);
    case 1:
      if (length - *index < 8) return false;
      *index += 8;
      return true;
    case 2:
      if (!readVarint(bytes, length, index, &fieldLength) ||
          fieldLength > length - *index) {
        return false;
      }
      *index += static_cast<size_t>(fieldLength);
      return true;
    case 5:
      if (length - *index < 4) return false;
      *index += 4;
      return true;
    default:
      return false;
  }
}

int32_t decodeSigned32(uint64_t encoded) {
  const int64_t magnitude = static_cast<int64_t>(encoded >> 1);
  return static_cast<int32_t>((encoded & 1) != 0 ? -magnitude - 1 : magnitude);
}

bool parseAnalog(const uint8_t* bytes, size_t length, int* location,
                 int* value) {
  size_t index = 0;
  *location = 0;
  *value = 0;
  while (index < length) {
    uint64_t key = 0;
    if (!readVarint(bytes, length, &index, &key)) return false;
    const uint64_t field = key >> 3;
    const uint64_t wire = key & 0x07;
    uint64_t decoded = 0;
    if (field == 1 && wire == 0) {
      if (!readVarint(bytes, length, &index, &decoded) || decoded > INT_MAX) {
        return false;
      }
      *location = static_cast<int>(decoded);
    } else if (field == 2 && wire == 0) {
      if (!readVarint(bytes, length, &index, &decoded) ||
          decoded > UINT32_MAX) {
        return false;
      }
      *value = decodeSigned32(decoded);
    } else if (!skipField(wire, bytes, length, &index)) {
      return false;
    }
  }
  return true;
}

}  // namespace

const char* rideButtonName(RideButton button) {
  constexpr const char* kNames[] = {
      "navigationLeft",
      "navigationUp",
      "navigationRight",
      "navigationDown",
      "a",
      "b",
      "y",
      "z",
      "shiftUpLeft",
      "shiftDownLeft",
      "powerUpLeft",
      "onOffLeft",
      "shiftUpRight",
      "shiftDownRight",
      "powerUpRight",
      "onOffRight",
      "paddleLeft",
      "paddleRight",
  };
  const uint8_t index = static_cast<uint8_t>(button);
  return index < static_cast<uint8_t>(RideButton::Count) ? kNames[index]
                                                         : "unknown";
}

bool decodeRideButtons(const uint8_t* bytes, size_t length,
                       uint32_t* pressedMask, int analogThreshold) {
  if (bytes == nullptr || pressedMask == nullptr || analogThreshold < 0) {
    return false;
  }

  size_t index = 0;
  uint32_t buttonMap = UINT32_MAX;
  uint32_t pressed = 0;
  while (index < length) {
    uint64_t key = 0;
    if (!readVarint(bytes, length, &index, &key)) return false;
    const uint64_t field = key >> 3;
    const uint64_t wire = key & 0x07;
    if (field == 1 && wire == 0) {
      uint64_t decoded = 0;
      if (!readVarint(bytes, length, &index, &decoded) ||
          decoded > UINT32_MAX) {
        return false;
      }
      buttonMap = static_cast<uint32_t>(decoded);
    } else if (field == 3 && wire == 2) {
      uint64_t fieldLength = 0;
      if (!readVarint(bytes, length, &index, &fieldLength) ||
          fieldLength > length - index) {
        return false;
      }
      int location = 0;
      int value = 0;
      if (!parseAnalog(bytes + index, static_cast<size_t>(fieldLength),
                       &location, &value)) {
        return false;
      }
      index += static_cast<size_t>(fieldLength);
      const int64_t magnitude = value < 0 ? -static_cast<int64_t>(value)
                                          : static_cast<int64_t>(value);
      if (magnitude >= analogThreshold) {
        if (location == 0) pressed |= rideButtonBit(RideButton::PaddleLeft);
        if (location == 1) pressed |= rideButtonBit(RideButton::PaddleRight);
      }
    } else if (!skipField(wire, bytes, length, &index)) {
      return false;
    }
  }

  for (const auto& digital : kDigitalButtons) {
    if ((buttonMap & digital.mask) == 0) {
      pressed |= rideButtonBit(digital.button);
    }
  }
  *pressedMask = pressed;
  return true;
}
