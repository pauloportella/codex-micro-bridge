#pragma once

#include <stddef.h>
#include <stdint.h>

enum class RideButton : uint8_t {
  NavigationLeft,
  NavigationUp,
  NavigationRight,
  NavigationDown,
  A,
  B,
  Y,
  Z,
  ShiftUpLeft,
  ShiftDownLeft,
  PowerUpLeft,
  OnOffLeft,
  ShiftUpRight,
  ShiftDownRight,
  PowerUpRight,
  OnOffRight,
  PaddleLeft,
  PaddleRight,
  Count,
};

constexpr uint32_t rideButtonBit(RideButton button) {
  return uint32_t{1} << static_cast<uint8_t>(button);
}

const char* rideButtonName(RideButton button);

// Decodes the protobuf status payload following a Zwift controller 0x23
// notification. The returned mask contains every currently pressed control.
bool decodeRideButtons(const uint8_t* bytes, size_t length,
                       uint32_t* pressedMask, int analogThreshold = 25);
