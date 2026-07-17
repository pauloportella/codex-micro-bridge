import Foundation

public struct CodexAction: Codable, Equatable {
  public let type: String
  public let key: String?
  public let agent: Int?
  public let durationMs: Int?
  public let direction: String?
  public let mode: String?
  public let maxSteps: Int?

  public init(
    type: String,
    key: String? = nil,
    agent: Int? = nil,
    durationMs: Int? = nil,
    direction: String? = nil,
    mode: String? = nil,
    maxSteps: Int? = nil
  ) {
    self.type = type
    self.key = key
    self.agent = agent
    self.durationMs = durationMs
    self.direction = direction
    self.mode = mode
    self.maxSteps = maxSteps
  }
}

public struct RideMapping: Codable, Equatable {
  public let button: String
  public let action: CodexAction

  public init(button: String, action: CodexAction) {
    self.button = button
    self.action = action
  }
}

public struct RideConfig: Codable, Equatable {
  public let serialPort: String?
  public let mappings: [RideMapping]

  public init(serialPort: String? = nil, mappings: [RideMapping]) {
    self.serialPort = serialPort
    self.mappings = mappings
  }

  public func validated() throws -> RideConfig {
    guard !mappings.isEmpty else {
      throw BridgeError("Zwift Ride config needs at least one mapping")
    }
    if let serialPort, serialPort.isEmpty {
      throw BridgeError("Zwift Ride serialPort must be a non-empty string")
    }

    var seen = Set<String>()
    for (offset, mapping) in mappings.enumerated() {
      let position = offset + 1
      guard RideButton.names.contains(mapping.button) else {
        throw BridgeError("Mapping \(position) has an unknown Zwift Ride button: \(mapping.button)")
      }
      guard seen.insert(mapping.button).inserted else {
        throw BridgeError("Zwift Ride button is mapped more than once: \(mapping.button)")
      }
      guard ["key", "press", "turn"].contains(mapping.action.type) else {
        throw BridgeError("Mapping \(position) action must be key, press, or turn")
      }
      if ["key", "press"].contains(mapping.action.type) {
        guard let key = mapping.action.key, !key.isEmpty else {
          throw BridgeError("Mapping \(position) requires a Codex key")
        }
      }
      if mapping.action.type == "turn",
        !["cw", "ccw"].contains(mapping.action.direction?.lowercased() ?? "")
      {
        throw BridgeError("Mapping \(position) turn direction must be cw or ccw")
      }
    }
    return self
  }
}

public struct MidiMapping: Codable, Equatable {
  public let message: String
  public let channel: Int?
  public let number: Int
  public let threshold: Int?
  public let action: CodexAction

  public init(
    message: String,
    channel: Int? = nil,
    number: Int,
    threshold: Int? = nil,
    action: CodexAction
  ) {
    self.message = message
    self.channel = channel
    self.number = number
    self.threshold = threshold
    self.action = action
  }
}

public struct MidiConfig: Codable, Equatable {
  public let deviceContains: String?
  public let serialPort: String?
  public let mappings: [MidiMapping]

  public init(
    deviceContains: String? = nil,
    serialPort: String? = nil,
    mappings: [MidiMapping]
  ) {
    self.deviceContains = deviceContains
    self.serialPort = serialPort
    self.mappings = mappings
  }

  public func validated() throws -> MidiConfig {
    guard !mappings.isEmpty else {
      throw BridgeError("MIDI config needs at least one mapping")
    }
    if let serialPort, serialPort.isEmpty {
      throw BridgeError("MIDI serialPort must be a non-empty string")
    }

    for (offset, mapping) in mappings.enumerated() {
      let position = offset + 1
      guard ["note", "cc"].contains(mapping.message) else {
        throw BridgeError("Mapping \(position) message must be note or cc")
      }
      guard (0...127).contains(mapping.number) else {
        throw BridgeError("Mapping \(position) number must be from 0 through 127")
      }
      if let channel = mapping.channel, !(1...16).contains(channel) {
        throw BridgeError("Mapping \(position) channel must be from 1 through 16")
      }
      guard ["key", "press", "turn", "dial"].contains(mapping.action.type) else {
        throw BridgeError("Mapping \(position) has an invalid action type")
      }
      if ["key", "press"].contains(mapping.action.type),
        mapping.action.key?.isEmpty != false
      {
        throw BridgeError("\(mapping.action.type) action requires a key")
      }
    }
    return self
  }
}

public enum ConfigurationLoader {
  public static func ride(at path: String) throws -> RideConfig {
    try decode(RideConfig.self, at: path, name: "Zwift Ride").validated()
  }

  public static func midi(at path: String) throws -> MidiConfig {
    try decode(MidiConfig.self, at: path, name: "MIDI").validated()
  }

  private static func decode<T: Decodable>(_ type: T.Type, at path: String, name: String) throws
    -> T
  {
    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw BridgeError("Cannot read \(name) config \(path): \(error.localizedDescription)")
    }
  }
}

public enum ProjectPaths {
  public static func root(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> String
  {
    if let configured = environment["CODEX_MICRO_BRIDGE_ROOT"], !configured.isEmpty {
      return configured
    }
    return FileManager.default.currentDirectoryPath
  }

  public static func config(_ name: String) -> String {
    URL(fileURLWithPath: root()).appendingPathComponent("config/\(name)").path
  }
}
