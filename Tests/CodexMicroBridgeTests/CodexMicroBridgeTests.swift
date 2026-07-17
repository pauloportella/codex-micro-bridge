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

final class CompanionTests: XCTestCase {
  func testAggregatesThreadStatesInBundleDisplayPriorityOrder() {
    let feedback = [
      CodexFeedback(agent: 0, state: .unread),
      CodexFeedback(agent: 1, state: .thinking),
      CodexFeedback(agent: 2, state: .needsInput),
      CodexFeedback(agent: 3, state: .error),
    ]

    XCTAssertEqual(CodexFeedbackProjector.aggregate(feedback), .error)
    XCTAssertEqual(CodexFeedbackProjector.aggregate(Array(feedback.dropLast())), .needsInput)
    XCTAssertEqual(CodexFeedbackProjector.aggregate(Array(feedback.prefix(2))), .thinking)
    XCTAssertEqual(CodexFeedbackProjector.aggregate(Array(feedback.prefix(1))), .unread)
    XCTAssertEqual(CodexFeedbackProjector.aggregate([]), .off)
  }

  func testDecodesM5StickCButtonAndMicrophoneEvents() {
    XCTAssertEqual(CompanionProtocol.decode("BUTTON A DOWN"), .button(name: "a", state: "down"))
    XCTAssertEqual(CompanionProtocol.decode("MIC LEVEL 42"), .microphone(level: 42))
    XCTAssertEqual(CompanionProtocol.decode("DISPLAY NEEDS YOU"), .display(state: "NEEDS YOU"))
  }

  func testDecodesExactCodexThreadLightingPayload() {
    let feedback = CodexFeedbackDecoder.decode(
      #"FEEDBACK {"id":7,"method":"v.oai.thstatus","params":[{"id":0,"c":3166206,"b":1,"e":2,"s":0.4,"sk":0,"sa":0},{"id":1,"c":65356,"b":1,"e":1,"s":0,"sk":0,"sa":0},{"id":2,"c":16777215,"b":1,"e":1,"s":0,"sk":0,"sa":0},{"id":3,"c":16739584,"b":1,"e":4,"s":0.4,"sk":0,"sa":0},{"id":4,"c":16711731,"b":1,"e":1,"s":0,"sk":0,"sa":0},{"id":5,"c":0,"b":0,"e":0,"s":0,"sk":0,"sa":0}]}"#
    )
    XCTAssertEqual(
      feedback,
      [
        CodexFeedback(agent: 0, state: .thinking),
        CodexFeedback(agent: 1, state: .unread),
        CodexFeedback(agent: 2, state: .idle),
        CodexFeedback(agent: 3, state: .needsInput),
        CodexFeedback(agent: 4, state: .error),
        CodexFeedback(agent: 5, state: .off),
      ])
  }

  func testDecodesExactCodexVoiceLightingPayloadsAndLifecycle() {
    func lighting(_ effect: Int, _ color: Int) -> CodexLightingFeedback {
      let line =
        #"FEEDBACK {"id":8,"method":"v.oai.rgbcfg","params":{"ambient":{"e":\#(effect),"b":1,"s":0.4,"m":0,"c":\#(color)},"keys":{"e":0,"b":0,"s":0,"m":0,"c":0}}}"#
      guard case .lighting(let feedback) = CodexFeedbackDecoder.decodeMessage(line) else {
        XCTFail("rgbcfg payload did not decode")
        return CodexLightingFeedback(ambientEffect: -1, ambientColor: -1, ambientBrightness: 0)
      }
      return feedback
    }

    var resolver = CodexVoiceStateResolver()
    XCTAssertEqual(resolver.consume(lighting(2, 0x2E8B57)), .recording)
    XCTAssertNil(resolver.consume(lighting(2, 0x2E8B57)))
    XCTAssertEqual(resolver.consume(lighting(2, 0xFFFFFF)), .processing)
    XCTAssertEqual(resolver.consume(lighting(1, 0xFFFFFF)), .completed)
    XCTAssertEqual(resolver.completeDisplayWindow(), .idle)
    XCTAssertNil(resolver.completeDisplayWindow())
  }

  func testSolidWhiteDoesNotInventCompletedWithoutActiveVoice() {
    let line =
      #"FEEDBACK {"id":9,"method":"v.oai.rgbcfg","params":{"ambient":{"e":1,"b":1,"s":0,"m":0,"c":16777215},"keys":{"e":0,"b":0,"s":0,"m":0,"c":0}}}"#
    guard case .lighting(let feedback) = CodexFeedbackDecoder.decodeMessage(line) else {
      return XCTFail("rgbcfg payload did not decode")
    }
    var resolver = CodexVoiceStateResolver()
    XCTAssertNil(resolver.consume(feedback))
    XCTAssertEqual(resolver.state, .idle)
  }

  func testCompanionMapperDoublePressesVoiceInputToToggle() {
    let mapper = CompanionMapper(mappings: [
      CompanionMapping(button: "a", action: CodexAction(type: "toggle", key: "ACT10"))
    ])
    XCTAssertEqual(
      mapper.process(button: "a", state: "down"),
      [
        .press(key: "ACT10", durationMs: 60),
        .press(key: "ACT10", durationMs: 60),
      ]
    )
    XCTAssertEqual(mapper.process(button: "a", state: "up"), [])
  }

  func testRideConfigWithoutCompanionFieldsRemainsValid() throws {
    let json = #"{"mappings":[{"button":"a","action":{"type":"key","key":"AG00"}}]}"#
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(RideConfig.self, from: data).validated()
    XCTAssertFalse(config.companionEnabled)
    XCTAssertEqual(config.companionMappings, [])
  }

  func testCodexConversationLifecycleTracksWorkingAndCompletion() {
    var tracker = CodexActivityTracker()
    XCTAssertTrue(
      tracker.consume(
        #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#
      ))
    XCTAssertEqual(tracker.state, .working)
    XCTAssertTrue(
      tracker.consume(
        #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"question-1"}}"#
      ))
    XCTAssertEqual(tracker.state, .needsInput)
    XCTAssertTrue(
      tracker.consume(
        #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"question-1"}}"#
      ))
    XCTAssertEqual(tracker.state, .working)
    XCTAssertTrue(
      tracker.consume(
        #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
      ))
    XCTAssertEqual(tracker.state, .idle)

    tracker.consume(
      #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}"#
    )
    tracker.consume(
      #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-2"}}"#
    )
    XCTAssertEqual(tracker.state, .idle)
  }

  func testNewTurnSupersedesOrphanedTurnInSameSession() {
    var tracker = CodexActivityTracker()
    tracker.consume(
      #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"orphaned-turn"}}"#
    )
    tracker.consume(
      #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"current-turn"}}"#
    )
    tracker.consume(
      #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"current-turn"}}"#
    )

    XCTAssertEqual(tracker.state, .idle)
    XCTAssertTrue(tracker.activeTurnIDs.isEmpty)
  }

  func testSpeechTrackerEmitsOnlyLastAssistantResponseAtCompletion() {
    var tracker = CodexSpeechTurnTracker()
    XCTAssertEqual(
      tracker.consume(
        #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#),
      .taskStarted
    )
    XCTAssertNil(
      tracker.consume(
        #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Working update"}]}}"#
      ))
    XCTAssertNil(
      tracker.consume(
        #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Final response"}]}}"#
      ))
    XCTAssertEqual(
      tracker.consume(
        #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#),
      .responseCompleted("Final response")
    )
  }

  func testSpeechTrackerDropsAbortedAndUnscopedResponses() {
    var tracker = CodexSpeechTurnTracker()
    XCTAssertNil(
      tracker.consume(
        #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Historical"}]}}"#
      ))
    XCTAssertEqual(
      tracker.consume(
        #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}"#),
      .taskStarted
    )
    XCTAssertNil(
      tracker.consume(
        #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Cancelled"}]}}"#
      ))
    XCTAssertEqual(
      tracker.consume(
        #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-2"}}"#),
      .turnAborted
    )
    XCTAssertNil(
      tracker.consume(
        #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-2"}}"#))
  }

  func testSpeechSanitizerMakesAPISizedChunksWithoutDroppingText() {
    let source =
      "A [link](https://example.com).\n```swift\nlet secret = true\n```\n"
      + String(repeating: "word ", count: 2_000)
    let cleaned = SpeechTextSanitizer.clean(source)
    let chunks = SpeechTextSanitizer.chunks(cleaned, maximumLength: 400)
    XCTAssertFalse(cleaned.contains("https://"))
    XCTAssertFalse(cleaned.contains("let secret"))
    XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 400 })
    XCTAssertEqual(chunks.joined(separator: " "), cleaned)
  }

  func testPCM16StreamAssemblerPreservesSamplesAcrossOddNetworkChunks() {
    var assembler = PCM16StreamAssembler()
    let chunks = [Data([0x01]), Data([0x02, 0x03, 0x04]), Data([0x05]), Data([0x06])]
    let aligned = chunks.map { assembler.append($0) }

    XCTAssertEqual(aligned.map(\.count), [0, 4, 0, 2])
    XCTAssertEqual(aligned.reduce(into: Data()) { $0.append($1) }, Data([1, 2, 3, 4, 5, 6]))
    XCTAssertFalse(assembler.hasIncompleteSample)

    _ = assembler.append(Data([0x07]))
    XCTAssertTrue(assembler.hasIncompleteSample)
  }

  func testActiveConversationCorrectsIdleLightingToWorkingBlue() {
    let idle = (0..<6).map { CodexFeedback(agent: $0, state: .idle) }
    let projected = CodexFeedbackProjector.project(idle, conversationState: .working)
    XCTAssertEqual(projected[0], CodexFeedback(agent: 0, state: .thinking))
    XCTAssertEqual(projected.dropFirst().map(\.state), Array(repeating: .idle, count: 5))
    XCTAssertEqual(CodexFeedbackProjector.project(idle, conversationState: .idle), idle)
  }

  func testPendingQuestionProjectsBundleAwaitingResponseOrange() {
    let idle = (0..<6).map { CodexFeedback(agent: $0, state: .idle) }
    let projected = CodexFeedbackProjector.project(idle, conversationState: .needsInput)
    XCTAssertEqual(projected[0], CodexFeedback(agent: 0, state: .needsInput))
    XCTAssertEqual(projected.dropFirst().map(\.state), Array(repeating: .idle, count: 5))
  }

  func testInputAndErrorLightingOutrankWorkingCorrection() {
    let feedback = [
      CodexFeedback(agent: 0, state: .idle),
      CodexFeedback(agent: 1, state: .needsInput),
      CodexFeedback(agent: 2, state: .error),
    ]
    let projected = CodexFeedbackProjector.project(feedback, conversationState: .working)
    XCTAssertEqual(projected[0].state, .idle)
    XCTAssertEqual(projected[1].state, .needsInput)
    XCTAssertEqual(projected[2].state, .error)
    XCTAssertFalse(projected.contains { $0.state == .thinking })
  }

  func testActivityMonitorObservesSessionFileStartAndCompletion() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-activity-\(UUID().uuidString)", isDirectory: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy/MM/dd"
    let day = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let session = day.appendingPathComponent("rollout-test.jsonl")
    try Data(
      (#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-live"}}"#
        + "\n").utf8
    ).write(to: session)

    let initialWorking = expectation(description: "monitor reports initial working")
    let resumedWorking = expectation(description: "monitor resumes working after question")
    let needsInput = expectation(description: "monitor reports pending question")
    let idle = expectation(description: "monitor reports idle after completion")
    let speechCompletion = expectation(
      description: "monitor emits only the live completed response")
    var sawInitialWorking = false
    var speechEvents: [CodexSpeechEvent] = []
    let monitor = CodexActivityMonitor(
      sessionsRoot: root,
      pollInterval: 0.05,
      onSpeechEvent: { event in
        speechEvents.append(event)
        if case .responseCompleted = event { speechCompletion.fulfill() }
      },
      onChange: { state in
        switch state {
        case .working:
          if sawInitialWorking {
            resumedWorking.fulfill()
          } else {
            sawInitialWorking = true
            initialWorking.fulfill()
          }
        case .needsInput: needsInput.fulfill()
        case .idle: idle.fulfill()
        }
      }
    )
    monitor.start()
    wait(for: [initialWorking], timeout: 2)

    let handle = try FileHandle(forWritingTo: session)
    try handle.seekToEnd()
    try handle.write(
      contentsOf: Data(
        (#"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"question-live"}}"#
          + "\n").utf8
      ))
    try handle.synchronize()
    wait(for: [needsInput], timeout: 2)

    try handle.write(
      contentsOf: Data(
        (#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"question-live"}}"#
          + "\n").utf8
      ))
    try handle.synchronize()
    wait(for: [resumedWorking], timeout: 2)

    try handle.write(
      contentsOf: Data(
        (#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Live final"}]}}"#
          + "\n"
          + #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-live"}}"#
          + "\n").utf8
      ))
    try handle.close()
    wait(for: [idle, speechCompletion], timeout: 2)
    XCTAssertEqual(speechEvents, [.responseCompleted("Live final")])
    monitor.stop()
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
