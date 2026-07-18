#include "ride_protocol.h"

#include <assert.h>
#include <string.h>

int main() {
  uint32_t pressed = 0;

  const uint8_t idle[] = {0x08, 0xff, 0xff, 0xff, 0xff, 0x0f};
  assert(decodeRideButtons(idle, sizeof(idle), &pressed));
  assert(pressed == 0);

  const uint8_t navigationLeft[] = {0x08, 0xfe, 0xff, 0xff, 0xff, 0x0f};
  assert(decodeRideButtons(navigationLeft, sizeof(navigationLeft), &pressed));
  assert(pressed == rideButtonBit(RideButton::NavigationLeft));

  const uint8_t paddleLeft[] = {
      0x08, 0xff, 0xff, 0xff, 0xff, 0x0f, 0x1a, 0x02, 0x10, 0x3c,
  };
  assert(decodeRideButtons(paddleLeft, sizeof(paddleLeft), &pressed));
  assert(pressed == rideButtonBit(RideButton::PaddleLeft));

  const uint8_t negativePaddleRight[] = {
      0x08, 0xff, 0xff, 0xff, 0xff, 0x0f, 0x1a, 0x04, 0x08, 0x01, 0x10, 0x3b,
  };
  assert(decodeRideButtons(negativePaddleRight, sizeof(negativePaddleRight),
                           &pressed));
  assert(pressed == rideButtonBit(RideButton::PaddleRight));

  const uint8_t truncated[] = {0x1a, 0x04, 0x08};
  assert(!decodeRideButtons(truncated, sizeof(truncated), &pressed));

  const uint8_t overflowingVarint[] = {
      0x08, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80,
      0x80, 0x80, 0x80, 0x02,
  };
  assert(!decodeRideButtons(overflowingVarint, sizeof(overflowingVarint),
                            &pressed));
  assert(strcmp(rideButtonName(RideButton::ShiftUpRight), "shiftUpRight") == 0);
}
