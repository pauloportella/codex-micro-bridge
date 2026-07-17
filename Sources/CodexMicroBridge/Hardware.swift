import Darwin
import Foundation

public enum HardwareCommand: Equatable {
  case hid(key: String, action: Int, agent: Int? = nil)
  case press(key: String, durationMs: Int = 60, agent: Int? = nil)
  case joystick(angle: Double, distance: Double)
}

public enum HardwareProtocol {
  public static func encode(_ command: HardwareCommand) throws -> String {
    switch command {
    case .hid(let key, let action, let agent):
      return try encodeHID(key: key, action: action, agent: agent)
    case .press(let key, _, let agent):
      return try encodeHID(key: key, action: 1, agent: agent)
    case .joystick(let angle, let distance):
      guard angle.isFinite else { throw BridgeError("joystick angle must be finite") }
      guard distance.isFinite else { throw BridgeError("joystick distance must be finite") }
      return "RAD \(format(angle)) \(format(distance))\n"
    }
  }

  public static func encodeHID(key: String, action: Int, agent: Int? = nil) throws -> String {
    let valid =
      !key.isEmpty
      && key.unicodeScalars.allSatisfy {
        ("A"..."Z").contains(Character(String($0))) || ("0"..."9").contains(Character(String($0)))
          || $0 == "_"
      }
    guard valid else {
      throw BridgeError("Hardware HID key must contain only A-Z, 0-9, or underscore")
    }
    guard (0...2).contains(action) else {
      throw BridgeError("Hardware HID act must be 0, 1, or 2")
    }
    if let agent, agent < 0 {
      throw BridgeError("Hardware HID agent must be a non-negative integer")
    }
    return "HID \(key) \(action)\(agent.map { " \($0)" } ?? "")\n"
  }

  private static func format(_ number: Double) -> String {
    String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), number)
  }
}

public enum HardwarePorts {
  public static func list(
    devDirectory: String = "/dev",
    fileManager: FileManager = .default
  ) throws -> [String] {
    do {
      return try fileManager.contentsOfDirectory(atPath: devDirectory)
        .filter { name in
          name.range(
            of: #"^cu\.usbmodemCDXMICRO\d*$"#,
            options: .regularExpression
          ) != nil
        }
        .sorted()
        .map { URL(fileURLWithPath: devDirectory).appendingPathComponent($0).path }
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return []
    }
  }

  public static func resolve(_ configuredPort: String?) throws -> String {
    if let configuredPort {
      guard FileManager.default.fileExists(atPath: configuredPort) else {
        throw BridgeError("Codex Micro serial port does not exist: \(configuredPort)")
      }
      return configuredPort
    }

    let ports = try list()
    guard !ports.isEmpty else {
      throw BridgeError("No physical Codex Micro Bridge found. Connect the flashed Leonardo.")
    }
    guard ports.count == 1 else {
      throw BridgeError(
        "More than one physical bridge found; set serialPort to one of: \(ports.joined(separator: ", "))"
      )
    }
    return ports[0]
  }
}

public final class HardwareTransport {
  public let port: String
  private var descriptor: Int32
  private var feedbackSource: DispatchSourceRead?
  private var feedbackBytes: [UInt8] = []

  public init(port configuredPort: String? = nil) throws {
    port = try HardwarePorts.resolve(configuredPort)
    descriptor = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
    guard descriptor >= 0 else {
      throw BridgeError("Could not open \(port): \(String(cString: strerror(errno)))")
    }

    do {
      try configureSerial(descriptor, port: port)
    } catch {
      Darwin.close(descriptor)
      descriptor = -1
      throw error
    }
  }

  deinit {
    close()
  }

  public func send(_ command: HardwareCommand) throws {
    switch command {
    case .press(let key, let durationMs, let agent):
      try write(HardwareProtocol.encodeHID(key: key, action: 1, agent: agent))
      Thread.sleep(forTimeInterval: Double(max(1, durationMs)) / 1_000)
      try write(HardwareProtocol.encodeHID(key: key, action: 0, agent: agent))
    default:
      try write(HardwareProtocol.encode(command))
    }
  }

  public func startFeedback(
    queue: DispatchQueue = DispatchQueue(label: "Codex Micro hardware feedback"),
    onLine: @escaping (String) -> Void
  ) {
    guard feedbackSource == nil, descriptor >= 0 else { return }
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    source.setEventHandler { [weak self] in
      self?.readFeedback(onLine: onLine)
    }
    feedbackSource = source
    source.resume()
  }

  public func replayFeedback() throws {
    try write("REPLAY\n")
  }

  public func close() {
    guard descriptor >= 0 else { return }
    feedbackSource?.cancel()
    feedbackSource = nil
    Darwin.close(descriptor)
    descriptor = -1
  }

  private func readFeedback(onLine: (String) -> Void) {
    var buffer = [UInt8](repeating: 0, count: 512)
    while descriptor >= 0 {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count > 0 {
        feedbackBytes.append(contentsOf: buffer.prefix(count))
        while let newline = feedbackBytes.firstIndex(of: 0x0a) {
          var line = Array(feedbackBytes[..<newline])
          feedbackBytes.removeFirst(newline + 1)
          if line.last == 0x0d { line.removeLast() }
          if let text = String(bytes: line, encoding: .utf8), !text.isEmpty {
            onLine(text)
          }
        }
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
      return
    }
  }

  private func write(_ line: String) throws {
    let bytes = Array(line.utf8)
    var written = 0
    while written < bytes.count {
      let result = bytes.withUnsafeBytes { buffer in
        Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), bytes.count - written)
      }
      if result < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          usleep(1_000)
          continue
        }
        throw BridgeError("Could not write to \(port): \(String(cString: strerror(errno)))")
      }
      written += result
    }
  }
}

func configureSerial(_ descriptor: Int32, port: String) throws {
  var options = termios()
  guard tcgetattr(descriptor, &options) == 0 else {
    throw BridgeError("Could not configure \(port): \(String(cString: strerror(errno)))")
  }
  cfmakeraw(&options)
  options.c_cflag |= tcflag_t(CLOCAL | CREAD)
  options.c_cflag &= ~tcflag_t(CSTOPB | PARENB | CSIZE)
  options.c_cflag |= tcflag_t(CS8)
  guard cfsetspeed(&options, speed_t(B115200)) == 0,
    tcsetattr(descriptor, TCSANOW, &options) == 0
  else {
    throw BridgeError("Could not configure \(port): \(String(cString: strerror(errno)))")
  }
}
