import Foundation

public struct MidiEvent: Equatable {
  public let source: String
  public let sourceID: Int32
  public let message: String
  public let channel: Int
  public let number: Int
  public let value: Int

  public init(
    source: String = "",
    sourceID: Int32 = 0,
    message: String,
    channel: Int,
    number: Int,
    value: Int
  ) {
    self.source = source
    self.sourceID = sourceID
    self.message = message
    self.channel = channel
    self.number = number
    self.value = value
  }
}

public final class MidiMapper {
  private let config: MidiConfig
  private var active: [String: Bool] = [:]

  public init(config: MidiConfig) throws {
    self.config = try config.validated()
  }

  public func process(_ event: MidiEvent) throws -> [HardwareCommand] {
    guard let normalized = normalize(event) else { return [] }
    var commands: [HardwareCommand] = []
    for (index, mapping) in config.mappings.enumerated()
    where matches(mapping, normalized) {
      commands += try apply(mapping, index: index, event: normalized)
    }
    return commands
  }

  private func apply(
    _ mapping: MidiMapping,
    index: Int,
    event: NormalizedMidiEvent
  ) throws -> [HardwareCommand] {
    let action = mapping.action
    let stateKey = "\(index):\(event.channel):\(event.number)"
    let previous = active[stateKey] ?? false
    let isActive =
      event.message == "note"
      ? event.active
      : event.value >= (mapping.threshold ?? 64)

    switch action.type {
    case "key":
      guard isActive != previous else { return [] }
      active[stateKey] = isActive
      return [.hid(key: try requiredKey(action), action: isActive ? 1 : 0, agent: action.agent)]
    case "press":
      active[stateKey] = isActive
      guard isActive, !previous else { return [] }
      return [
        .press(
          key: try requiredKey(action),
          durationMs: action.durationMs ?? 60,
          agent: action.agent
        )
      ]
    case "turn":
      active[stateKey] = isActive
      guard isActive, !previous else { return [] }
      let direction = action.direction?.lowercased()
      guard ["cw", "ccw"].contains(direction ?? "") else {
        throw BridgeError("turn action direction must be cw or ccw")
      }
      return [.hid(key: direction == "cw" ? "ENC_CW" : "ENC_CC", action: 2)]
    case "dial":
      guard event.message == "cc" else { return [] }
      return try Self.relativeDialCommands(value: event.value, action: action)
    default:
      return []
    }
  }

  public static func relativeDialCommands(
    value: Int,
    action: CodexAction
  ) throws -> [HardwareCommand] {
    guard (0...127).contains(value) else { return [] }
    let mode = action.mode ?? "twos-complement"
    let direction: String
    let steps: Int

    switch mode {
    case "twos-complement":
      guard value != 0, value != 64 else { return [] }
      direction = value < 64 ? "cw" : "ccw"
      steps = value < 64 ? value : 128 - value
    case "binary-offset":
      guard value != 64 else { return [] }
      direction = value > 64 ? "cw" : "ccw"
      steps = abs(value - 64)
    default:
      throw BridgeError("Unsupported relative dial mode: \(mode)")
    }

    let count = min(steps, action.maxSteps ?? 16)
    let command = HardwareCommand.hid(
      key: direction == "cw" ? "ENC_CW" : "ENC_CC",
      action: 2
    )
    return Array(repeating: command, count: max(0, count))
  }
}

private struct NormalizedMidiEvent {
  let message: String
  let channel: Int
  let number: Int
  let value: Int
  let active: Bool
}

private func normalize(_ event: MidiEvent) -> NormalizedMidiEvent? {
  guard (1...16).contains(event.channel), (0...127).contains(event.number) else { return nil }
  switch event.message {
  case "cc":
    return NormalizedMidiEvent(
      message: "cc",
      channel: event.channel,
      number: event.number,
      value: event.value,
      active: event.value >= 64
    )
  case "noteOn", "noteOff":
    return NormalizedMidiEvent(
      message: "note",
      channel: event.channel,
      number: event.number,
      value: event.value,
      active: event.message == "noteOn" && event.value > 0
    )
  default:
    return nil
  }
}

private func matches(_ mapping: MidiMapping, _ event: NormalizedMidiEvent) -> Bool {
  mapping.message == event.message && mapping.number == event.number
    && (mapping.channel == nil || mapping.channel == event.channel)
}

private func requiredKey(_ action: CodexAction) throws -> String {
  guard let key = action.key, !key.isEmpty else {
    throw BridgeError("\(action.type) action requires a key")
  }
  return key
}
