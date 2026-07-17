import XCTest

@testable import CodexMicroBridge

final class HardwareTests: XCTestCase {
  func testEncodesPhysicalCommandsForLeonardoSerialProtocol() throws {
    XCTAssertEqual(
      try HardwareProtocol.encodeHID(key: "ACT06", action: 1),
      "HID ACT06 1\n"
    )
    XCTAssertEqual(
      try HardwareProtocol.encodeHID(key: "AG00", action: 0, agent: 2),
      "HID AG00 0 2\n"
    )
    XCTAssertEqual(
      try HardwareProtocol.encode(.joystick(angle: 90, distance: 1)),
      "RAD 90 1\n"
    )
  }

  func testRejectsMalformedPhysicalCommands() {
    XCTAssertThrowsError(try HardwareProtocol.encodeHID(key: "bad key", action: 1))
    XCTAssertThrowsError(try HardwareProtocol.encodeHID(key: "ACT06", action: 3))
  }
}

final class MidiMapperTests: XCTestCase {
  func testNoteMappingPreservesButtonDownAndUp() throws {
    let mapper = try MidiMapper(
      config: MidiConfig(mappings: [
        MidiMapping(
          message: "note",
          channel: 1,
          number: 36,
          action: CodexAction(type: "key", key: "ACT06")
        )
      ]))

    XCTAssertEqual(
      try mapper.process(MidiEvent(message: "noteOn", channel: 1, number: 36, value: 100)),
      [.hid(key: "ACT06", action: 1)]
    )
    XCTAssertEqual(
      try mapper.process(MidiEvent(message: "noteOn", channel: 1, number: 36, value: 0)),
      [.hid(key: "ACT06", action: 0)]
    )
  }

  func testCCPressTriggersOnlyOnRisingThreshold() throws {
    let mapper = try MidiMapper(
      config: MidiConfig(mappings: [
        MidiMapping(
          message: "cc",
          number: 41,
          threshold: 64,
          action: CodexAction(type: "press", key: "AG00", durationMs: 40)
        )
      ]))
    let high = MidiEvent(message: "cc", channel: 2, number: 41, value: 127)
    let low = MidiEvent(message: "cc", channel: 2, number: 41, value: 0)

    XCTAssertEqual(try mapper.process(high), [.press(key: "AG00", durationMs: 40)])
    XCTAssertEqual(try mapper.process(high), [])
    XCTAssertEqual(try mapper.process(low), [])
    XCTAssertEqual(try mapper.process(high).count, 1)
  }

  func testRelativeDialUnderstandsTwoCommonEncoderModes() throws {
    XCTAssertEqual(
      try MidiMapper.relativeDialCommands(
        value: 1,
        action: CodexAction(type: "dial", mode: "twos-complement")
      ),
      [.hid(key: "ENC_CW", action: 2)]
    )
    XCTAssertEqual(
      try MidiMapper.relativeDialCommands(
        value: 127,
        action: CodexAction(type: "dial", mode: "twos-complement")
      ),
      [.hid(key: "ENC_CC", action: 2)]
    )
    XCTAssertEqual(
      try MidiMapper.relativeDialCommands(
        value: 65,
        action: CodexAction(type: "dial", mode: "binary-offset")
      ),
      [.hid(key: "ENC_CW", action: 2)]
    )
  }

  func testInvalidMappingIsRejectedBeforeOpeningMIDI() {
    XCTAssertThrowsError(
      try MidiConfig(mappings: [
        MidiMapping(
          message: "note",
          number: 128,
          action: CodexAction(type: "key", key: "ACT06")
        )
      ]).validated())
  }
}

final class RideMapperTests: XCTestCase {
  func testRideKeyMappingPreservesButtonDownAndUp() throws {
    let mapper = try RideMapper(
      config: RideConfig(mappings: [
        RideMapping(button: "a", action: CodexAction(type: "key", key: "AG04"))
      ]))
    XCTAssertEqual(
      mapper.process(RideButtonEvent(button: "a", state: "down")),
      [.hid(key: "AG04", action: 1)]
    )
    XCTAssertEqual(
      mapper.process(RideButtonEvent(button: "a", state: "up")),
      [.hid(key: "AG04", action: 0)]
    )
  }

  func testRideTurnMappingFiresOnlyOnButtonDown() throws {
    let mapper = try RideMapper(
      config: RideConfig(mappings: [
        RideMapping(
          button: "paddleRight",
          action: CodexAction(type: "turn", direction: "cw")
        )
      ]))
    XCTAssertEqual(
      mapper.process(RideButtonEvent(button: "paddleRight", state: "down")),
      [.hid(key: "ENC_CW", action: 2)]
    )
    XCTAssertEqual(mapper.process(RideButtonEvent(button: "paddleRight", state: "up")), [])
  }

  func testRideConfigRejectsUnknownAndDuplicateControls() {
    XCTAssertThrowsError(
      try RideConfig(mappings: [
        RideMapping(button: "nope", action: CodexAction(type: "key", key: "AG00"))
      ]).validated())
    XCTAssertThrowsError(
      try RideConfig(mappings: [
        RideMapping(button: "a", action: CodexAction(type: "key", key: "AG00")),
        RideMapping(button: "a", action: CodexAction(type: "key", key: "AG01")),
      ]).validated())
  }

  func testRideDecoderRecognizesDigitalAndAnalogInputs() throws {
    XCTAssertEqual(
      try RideProtocolDecoder.pressedButtons(in: [0x08, 0xfe, 0xff, 0xff, 0xff, 0x0f]),
      ["navigationLeft"]
    )
    XCTAssertEqual(
      try RideProtocolDecoder.pressedButtons(in: [
        0x08, 0xff, 0xff, 0xff, 0xff, 0x0f,
        0x1a, 0x02, 0x10, 0x3c,
      ]),
      ["paddleLeft"]
    )
  }
}
