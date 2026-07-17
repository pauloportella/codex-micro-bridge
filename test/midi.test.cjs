const assert = require("node:assert/strict");
const test = require("node:test");

const { MidiMapper, relativeDialCommands, validateMidiConfig } = require("../lib/midi.cjs");

test("note mapping preserves button down and up", () => {
  const mapper = new MidiMapper({
    mappings: [{
      message: "note",
      channel: 1,
      number: 36,
      action: { type: "key", key: "ACT06" },
    }],
  });

  assert.deepEqual(mapper.process({ message: "noteOn", channel: 1, number: 36, value: 100 }), [
    { type: "hid", key: "ACT06", act: 1 },
  ]);
  assert.deepEqual(mapper.process({ message: "noteOn", channel: 1, number: 36, value: 0 }), [
    { type: "hid", key: "ACT06", act: 0 },
  ]);
});

test("CC press triggers only on a rising threshold", () => {
  const mapper = new MidiMapper({
    mappings: [{
      message: "cc",
      number: 41,
      threshold: 64,
      action: { type: "press", key: "AG00", durationMs: 40 },
    }],
  });

  assert.deepEqual(mapper.process({ message: "cc", channel: 2, number: 41, value: 127 }), [
    { type: "press", key: "AG00", durationMs: 40 },
  ]);
  assert.deepEqual(mapper.process({ message: "cc", channel: 2, number: 41, value: 127 }), []);
  assert.deepEqual(mapper.process({ message: "cc", channel: 2, number: 41, value: 0 }), []);
  assert.equal(mapper.process({ message: "cc", channel: 2, number: 41, value: 127 }).length, 1);
});

test("relative dial understands two common encoder modes", () => {
  assert.deepEqual(relativeDialCommands(1, { mode: "twos-complement" }), [
    { type: "hid", key: "ENC_CW", act: 2 },
  ]);
  assert.deepEqual(relativeDialCommands(127, { mode: "twos-complement" }), [
    { type: "hid", key: "ENC_CC", act: 2 },
  ]);
  assert.deepEqual(relativeDialCommands(65, { mode: "binary-offset" }), [
    { type: "hid", key: "ENC_CW", act: 2 },
  ]);
});

test("invalid mapping is rejected before opening MIDI", () => {
  assert.throws(
    () => validateMidiConfig({ mappings: [{ message: "note", number: 128, action: { type: "key", key: "ACT06" } }] }),
    /number must be from 0 through 127/,
  );
});
