import CodexMicroBridge
import Foundation

do {
  var arguments = Array(CommandLine.arguments.dropFirst())
  var configuredPort: String?
  if let portIndex = arguments.firstIndex(of: "--port") {
    guard arguments.indices.contains(portIndex + 1) else {
      throw BridgeError("--port requires a device path")
    }
    configuredPort = arguments[portIndex + 1]
    arguments.removeSubrange(portIndex...(portIndex + 1))
  }

  let subcommand = arguments.first
  let rest = Array(arguments.dropFirst())
  if subcommand == "list" {
    let ports = try HardwarePorts.list()
    print(ports.isEmpty ? "No physical Codex Micro Bridge found." : ports.joined(separator: "\n"))
    exit(0)
  }

  let command = try parseCommand(subcommand, rest)
  let transport = try HardwareTransport(port: configuredPort)
  try transport.send(command)
  print("\(transport.port): sent \(subcommand ?? "command")")
} catch {
  writeError(error.localizedDescription)
  exit(1)
}

private func parseCommand(_ subcommand: String?, _ arguments: [String]) throws -> HardwareCommand {
  switch subcommand {
  case "press":
    let key = try required(arguments.first, "press requires a key, for example ACT06")
    return .press(key: key, durationMs: try integerOr(arguments[safe: 1], default: 60))
  case "down":
    return .hid(key: try required(arguments.first, "down requires a key"), action: 1)
  case "up":
    return .hid(key: try required(arguments.first, "up requires a key"), action: 0)
  case "agent":
    guard let text = arguments.first, let slot = Int(text), (0...5).contains(slot) else {
      throw BridgeError("agent requires a slot from 0 through 5")
    }
    return .press(key: "AG0\(slot)")
  case "command":
    guard let text = arguments.first,
      let slot = Int(text),
      [6, 7, 8, 9, 10, 12].contains(slot)
    else {
      throw BridgeError("command requires 6, 7, 8, 9, 10, or 12")
    }
    return .press(key: String(format: "ACT%02d", slot))
  case "turn":
    guard let direction = arguments.first?.lowercased(), ["cw", "ccw"].contains(direction) else {
      throw BridgeError("turn requires cw or ccw")
    }
    return .hid(key: direction == "cw" ? "ENC_CW" : "ENC_CC", action: 2)
  case "joystick":
    guard let angleText = arguments.first,
      let distanceText = arguments[safe: 1],
      let angle = Double(angleText),
      let distance = Double(distanceText)
    else {
      throw BridgeError("joystick requires numeric angle and distance")
    }
    return .joystick(angle: angle, distance: distance)
  default:
    throw BridgeError(
      "Usage: codex-micro-hardware [--port PATH] list | press KEY [ms] | down KEY | up KEY | agent 0-5 | command 6-10,12 | turn cw|ccw | joystick ANGLE DISTANCE"
    )
  }
}

private func required(_ value: String?, _ message: String) throws -> String {
  guard let value, !value.isEmpty else { throw BridgeError(message) }
  return value
}

private func integerOr(_ value: String?, default fallback: Int) throws -> Int {
  guard let value else { return fallback }
  guard let integer = Int(value) else { throw BridgeError("Invalid number: \(value)") }
  return integer
}

private func writeError(_ message: String) {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
}

extension Collection {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
