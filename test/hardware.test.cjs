const assert = require("node:assert/strict");
const test = require("node:test");

const {
  encodeHardwareCommand,
  encodeHid,
} = require("../lib/hardware.cjs");

test("encodes physical HID commands for the Leonardo serial protocol", () => {
  assert.equal(encodeHid("ACT06", 1), "HID ACT06 1\n");
  assert.equal(encodeHid("AG00", 0, 2), "HID AG00 0 2\n");
  assert.equal(
    encodeHardwareCommand({ type: "joystick", angle: 90, distance: 1 }),
    "RAD 90 1\n",
  );
});

test("rejects malformed physical commands", () => {
  assert.throws(() => encodeHid("bad key", 1), /only A-Z/);
  assert.throws(() => encodeHid("ACT06", 3), /must be 0, 1, or 2/);
  assert.throws(() => encodeHardwareCommand({ type: "unknown" }), /does not support/);
});
