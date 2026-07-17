import Foundation

public enum CompanionEvent: Equatable {
  case ready(name: String)
  case button(name: String, state: String)
  case microphone(level: Int)
  case display(state: String)
  case unknown(String)
}

public enum CompanionProtocol {
  public static func decode(_ line: String) -> CompanionEvent {
    let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let command = fields.first else { return .unknown(line) }
    switch command {
    case "READY", "HELLO":
      return .ready(name: fields.dropFirst().joined(separator: " "))
    case "BUTTON" where fields.count == 3:
      return .button(name: fields[1].lowercased(), state: fields[2].lowercased())
    case "MIC" where fields.count == 3 && fields[1] == "LEVEL":
      return .microphone(level: Int(fields[2]) ?? 0)
    case "DISPLAY" where fields.count >= 2:
      return .display(state: fields.dropFirst().joined(separator: " "))
    default:
      return .unknown(line)
    }
  }
}

public enum CodexAgentState: String, Equatable {
  case off = "OFF"
  case idle = "IDLE"
  case unread = "UNREAD"
  case thinking = "THINKING"
  case needsInput = "NEEDS_INPUT"
  case error = "ERROR"
}

public enum CodexVoiceState: String, Equatable {
  case idle = "IDLE"
  case recording = "RECORDING"
  case processing = "PROCESSING"
  case completed = "COMPLETED"

  public var companionCommand: String {
    "VOICE \(rawValue)"
  }
}

public struct CodexLightingFeedback: Equatable {
  public let ambientEffect: Int
  public let ambientColor: Int
  public let ambientBrightness: Double

  public init(ambientEffect: Int, ambientColor: Int, ambientBrightness: Double) {
    self.ambientEffect = ambientEffect
    self.ambientColor = ambientColor
    self.ambientBrightness = ambientBrightness
  }
}

public enum CodexFeedbackMessage: Equatable {
  case threads([CodexFeedback])
  case lighting(CodexLightingFeedback)
}

public struct CodexFeedback: Equatable {
  public let agent: Int
  public let state: CodexAgentState

  public init(agent: Int, state: CodexAgentState) {
    self.agent = agent
    self.state = state
  }

  public var companionCommand: String {
    "STATE \(agent) \(state.rawValue)"
  }
}

public enum CodexFeedbackDecoder {
  public static func decode(_ line: String) -> [CodexFeedback] {
    guard case .threads(let feedback) = decodeMessage(line) else { return [] }
    return feedback
  }

  public static func decodeMessage(_ line: String) -> CodexFeedbackMessage? {
    guard line.hasPrefix("FEEDBACK ") else { return nil }
    let json = String(line.dropFirst("FEEDBACK ".count))
    guard let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let method = object["method"] as? String
    else { return nil }

    if method == "v.oai.rgbcfg" {
      guard let params = object["params"] as? [String: Any],
        let ambient = params["ambient"] as? [String: Any],
        let effect = integer(ambient["e"]),
        let color = integer(ambient["c"])
      else { return nil }
      return .lighting(
        CodexLightingFeedback(
          ambientEffect: effect,
          ambientColor: color,
          ambientBrightness: double(ambient["b"]) ?? 1
        ))
    }

    guard method == "v.oai.thstatus", let params = object["params"] as? [[String: Any]]
    else { return nil }

    let feedback: [CodexFeedback] = params.compactMap { thread in
      guard let agent = integer(thread["id"]), let color = integer(thread["c"]) else { return nil }
      let brightness = double(thread["b"]) ?? 1
      let state: CodexAgentState
      if brightness == 0 || color == 0 {
        state = .off
      } else {
        switch color {
        case 0x304FFE: state = .thinking
        case 0x00FF4C: state = .unread
        case 0xFFFFFF: state = .idle
        case 0xFF6D00: state = .needsInput
        case 0xFF0033: state = .error
        default: return nil
        }
      }
      return CodexFeedback(agent: agent, state: state)
    }
    return .threads(feedback)
  }

  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
  }

  private static func double(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    return nil
  }
}

public struct CodexVoiceStateResolver {
  public private(set) var state: CodexVoiceState = .idle

  public init() {}

  @discardableResult
  public mutating func consume(_ lighting: CodexLightingFeedback) -> CodexVoiceState? {
    let next: CodexVoiceState
    if lighting.ambientBrightness > 0, lighting.ambientEffect == 2,
      lighting.ambientColor == 0x2E8B57
    {
      next = .recording
    } else if lighting.ambientBrightness > 0, lighting.ambientEffect == 2,
      lighting.ambientColor == 0xFFFFFF
    {
      next = .processing
    } else if lighting.ambientBrightness > 0, lighting.ambientEffect == 1,
      lighting.ambientColor == 0xFFFFFF,
      state == .recording || state == .processing
    {
      next = .completed
    } else if state == .recording || state == .processing {
      next = .idle
    } else {
      return nil
    }

    guard next != state else { return nil }
    state = next
    return next
  }

  @discardableResult
  public mutating func completeDisplayWindow() -> CodexVoiceState? {
    guard state == .completed else { return nil }
    state = .idle
    return .idle
  }
}

public final class CompanionMapper {
  private let mappings: [String: CodexAction]

  public init(mappings: [CompanionMapping]) {
    self.mappings = Dictionary(uniqueKeysWithValues: mappings.map { ($0.button, $0.action) })
  }

  public func process(button: String, state: String) -> [HardwareCommand] {
    guard let action = mappings[button], state == "down" || state == "up" else { return [] }
    switch action.type {
    case "key":
      guard let key = action.key else { return [] }
      return [.hid(key: key, action: state == "down" ? 1 : 0, agent: action.agent)]
    case "press":
      guard state == "down", let key = action.key else { return [] }
      return [.press(key: key, durationMs: action.durationMs ?? 60, agent: action.agent)]
    case "toggle":
      guard state == "down", let key = action.key else { return [] }
      let press = HardwareCommand.press(
        key: key,
        durationMs: action.durationMs ?? 60,
        agent: action.agent
      )
      return [press, press]
    case "turn":
      guard state == "down" else { return [] }
      return [.hid(key: action.direction?.lowercased() == "ccw" ? "ENC_CC" : "ENC_CW", action: 2)]
    default:
      return []
    }
  }
}
