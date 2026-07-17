const assert = require("node:assert/strict");
const test = require("node:test");

const { RideMapper, validateRideConfig } = require("../lib/ride.cjs");

test("Zwift Ride key mapping preserves button down and up", () => {
  const mapper = new RideMapper({
    mappings: [{ button: "a", action: { type: "key", key: "AG04" } }],
  });
  assert.deepEqual(mapper.process({ message: "button", button: "a", state: "down" }), [
    { type: "hid", key: "AG04", act: 1 },
  ]);
  assert.deepEqual(mapper.process({ message: "button", button: "a", state: "up" }), [
    { type: "hid", key: "AG04", act: 0 },
  ]);
});

test("Zwift Ride turn mapping fires only on button down", () => {
  const mapper = new RideMapper({
    mappings: [{ button: "paddleRight", action: { type: "turn", direction: "cw" } }],
  });
  assert.deepEqual(mapper.process({ message: "button", button: "paddleRight", state: "down" }), [
    { type: "hid", key: "ENC_CW", act: 2 },
  ]);
  assert.deepEqual(mapper.process({ message: "button", button: "paddleRight", state: "up" }), []);
});

test("Zwift Ride config rejects unknown and duplicate controls", () => {
  assert.throws(
    () => validateRideConfig({ mappings: [{ button: "nope", action: { type: "key", key: "AG00" } }] }),
    /unknown Zwift Ride button/,
  );
  assert.throws(
    () => validateRideConfig({ mappings: [
      { button: "a", action: { type: "key", key: "AG00" } },
      { button: "a", action: { type: "key", key: "AG01" } },
    ] }),
    /mapped more than once/,
  );
});
