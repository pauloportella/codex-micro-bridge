import Foundation

public enum RideButton {
  public static let names: Set<String> = [
    "navigationLeft", "navigationUp", "navigationRight", "navigationDown",
    "a", "b", "y", "z",
    "shiftUpLeft", "shiftDownLeft", "shiftUpRight", "shiftDownRight",
    "powerUpLeft", "powerUpRight", "onOffLeft", "onOffRight",
    "paddleLeft", "paddleRight",
  ]
}

public struct RideButtonEvent: Equatable {
  public let button: String
  public let state: String

  public init(button: String, state: String) {
    self.button = button
    self.state = state
  }
}

public final class RideMapper {
  private let byButton: [String: RideMapping]

  public init(config: RideConfig) throws {
    let config = try config.validated()
    byButton = Dictionary(uniqueKeysWithValues: config.mappings.map { ($0.button, $0) })
  }

  public func process(_ event: RideButtonEvent) -> [HardwareCommand] {
    guard ["down", "up"].contains(event.state),
      let mapping = byButton[event.button]
    else { return [] }
    let action = mapping.action

    switch action.type {
    case "key":
      guard let key = action.key else { return [] }
      return [
        .hid(
          key: key,
          action: event.state == "down" ? 1 : 0,
          agent: action.agent
        )
      ]
    case "press":
      guard event.state == "down", let key = action.key else { return [] }
      return [
        .press(
          key: key,
          durationMs: action.durationMs ?? 60,
          agent: action.agent
        )
      ]
    case "turn":
      guard event.state == "down" else { return [] }
      return [
        .hid(
          key: action.direction?.lowercased() == "cw" ? "ENC_CW" : "ENC_CC",
          action: 2
        )
      ]
    default:
      return []
    }
  }
}
