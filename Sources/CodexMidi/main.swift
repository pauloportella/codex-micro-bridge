import CodexMicroBridge
import CoreMIDI
import Foundation

private struct SourceDescription {
  let endpoint: MIDIEndpointRef
  let id: Int32
  let name: String
  let manufacturer: String
  let model: String

  var json: [String: Any] {
    ["id": id, "name": name, "manufacturer": manufacturer, "model": model]
  }
}

private final class SourceContext {
  let source: SourceDescription
  private let onEvent: (MidiEvent) -> Void
  private var runningStatus: UInt8?
  private var dataBytes: [UInt8] = []

  init(source: SourceDescription, onEvent: @escaping (MidiEvent) -> Void) {
    self.source = source
    self.onEvent = onEvent
  }

  func consume(_ bytes: [UInt8]) {
    for byte in bytes {
      if byte >= 0xf8 { continue }
      if byte & 0x80 != 0 {
        dataBytes.removeAll(keepingCapacity: true)
        runningStatus = byte < 0xf0 ? byte : nil
        continue
      }
      guard let statusByte = runningStatus else { continue }
      dataBytes.append(byte)
      let status = statusByte & 0xf0
      let requiredDataBytes = (status == 0xc0 || status == 0xd0) ? 1 : 2
      guard dataBytes.count >= requiredDataBytes else { continue }

      if status == 0x80 || status == 0x90 || status == 0xb0 {
        let message: String
        switch status {
        case 0x80: message = "noteOff"
        case 0x90: message = "noteOn"
        default: message = "cc"
        }
        onEvent(
          MidiEvent(
            source: source.name,
            sourceID: source.id,
            message: message,
            channel: Int(statusByte & 0x0f) + 1,
            number: Int(dataBytes[0]),
            value: Int(dataBytes[1])
          ))
      }
      dataBytes.removeAll(keepingCapacity: true)
    }
  }
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  let command = arguments.first ?? "help"
  let argument = arguments.count > 1 ? arguments[1] : nil

  switch command {
  case "validate":
    let path = configPath(argument)
    _ = try ConfigurationLoader.midi(at: path)
    print("Valid MIDI mapping: \(path)")
  case "list":
    let sources = availableSources()
    if sources.isEmpty {
      print("No MIDI inputs found.")
    } else {
      for source in sources {
        print("\(source.name) (id \(source.id))")
        let details = [source.manufacturer, source.model].filter { !$0.isEmpty }.joined(
          separator: " / ")
        if !details.isEmpty { print("  \(details)") }
      }
    }
  case "monitor":
    try runMIDI(deviceFilter: argument ?? "") { event in
      writeJSON(event.json)
    }
  case "run":
    let path = configPath(argument)
    let config = try ConfigurationLoader.midi(at: path)
    let mapper = try MidiMapper(config: config)
    let hardware = try HardwareTransport(port: config.serialPort)
    let commandQueue = DispatchQueue(label: "Codex Micro MIDI commands")
    writeError("Using physical bridge: \(hardware.port)")
    writeError("Using MIDI mapping: \(path)")
    try runMIDI(deviceFilter: config.deviceContains ?? "") { event in
      commandQueue.async {
        do {
          for command in try mapper.process(event) {
            try hardware.send(command)
            writeError(
              "\(event.source): \(event.message) \(event.number) -> \(command.keyDescription)")
          }
        } catch {
          writeError("MIDI command failed: \(error.localizedDescription)")
        }
      }
    }
  default:
    print(
      "Usage: codex-midi list | monitor [device-name] | validate [config.json] | run [config.json]")
  }
} catch {
  writeError(error.localizedDescription)
  exit(1)
}

private func runMIDI(
  deviceFilter: String,
  onEvent: @escaping (MidiEvent) -> Void
) throws -> Never {
  let filter = deviceFilter.trimmingCharacters(in: .whitespacesAndNewlines)
  let allSources = availableSources()
  let selectedSources = allSources.filter { source in
    filter.isEmpty
      || [source.name, source.manufacturer, source.model]
        .joined(separator: " ")
        .localizedCaseInsensitiveContains(filter)
  }
  guard !selectedSources.isEmpty else {
    let available = allSources.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
    throw BridgeError(
      "No matching MIDI input. Available inputs: \(available.isEmpty ? "none" : available)")
  }

  var client = MIDIClientRef()
  var inputPort = MIDIPortRef()
  let clientStatus = MIDIClientCreateWithBlock("Codex Micro MIDI Bridge" as CFString, &client) {
    _ in
  }
  guard clientStatus == noErr else {
    throw BridgeError("MIDIClientCreate failed: \(clientStatus)")
  }

  let portStatus = MIDIInputPortCreate(
    client,
    "Codex Micro Input" as CFString,
    { packetListPointer, _, sourceConnectionRefCon in
      guard let sourceConnectionRefCon else { return }
      let context = Unmanaged<SourceContext>
        .fromOpaque(sourceConnectionRefCon)
        .takeUnretainedValue()
      var packet = packetListPointer.pointee.packet
      for _ in 0..<packetListPointer.pointee.numPackets {
        let bytes = withUnsafeBytes(of: &packet.data) { rawBytes in
          Array(rawBytes.prefix(Int(packet.length)))
        }
        context.consume(bytes)
        packet = MIDIPacketNext(&packet).pointee
      }
    },
    nil,
    &inputPort
  )
  guard portStatus == noErr else {
    throw BridgeError("MIDIInputPortCreate failed: \(portStatus)")
  }

  var retainedContexts: [Unmanaged<SourceContext>] = []
  for source in selectedSources {
    let retained = Unmanaged.passRetained(SourceContext(source: source, onEvent: onEvent))
    let status = MIDIPortConnectSource(inputPort, source.endpoint, retained.toOpaque())
    if status == noErr {
      retainedContexts.append(retained)
      writeError("Listening to MIDI input: \(source.name)")
    } else {
      retained.release()
      writeError("Could not connect MIDI input \(source.name): \(status)")
    }
  }
  guard !retainedContexts.isEmpty else {
    throw BridgeError("Could not connect any matching MIDI input")
  }

  withExtendedLifetime((client, inputPort, retainedContexts)) {
    RunLoop.current.run()
  }
  fatalError("MIDI run loop stopped unexpectedly")
}

private func availableSources() -> [SourceDescription] {
  (0..<MIDIGetNumberOfSources()).map { index in
    let endpoint = MIDIGetSource(index)
    return SourceDescription(
      endpoint: endpoint,
      id: integerProperty(endpoint, kMIDIPropertyUniqueID),
      name: stringProperty(endpoint, kMIDIPropertyDisplayName),
      manufacturer: stringProperty(endpoint, kMIDIPropertyManufacturer),
      model: stringProperty(endpoint, kMIDIPropertyModel)
    )
  }
}

private func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String {
  var value: Unmanaged<CFString>?
  guard MIDIObjectGetStringProperty(object, property, &value) == noErr, let value else { return "" }
  return value.takeRetainedValue() as String
}

private func integerProperty(_ object: MIDIObjectRef, _ property: CFString) -> Int32 {
  var value: Int32 = 0
  _ = MIDIObjectGetIntegerProperty(object, property, &value)
  return value
}

private func configPath(_ argument: String?) -> String {
  URL(
    fileURLWithPath: argument ?? ProjectPaths.config("midi.example.json")
  ).standardized.path
}

private func writeJSON(_ value: Any) {
  guard let data = try? JSONSerialization.data(withJSONObject: value),
    let newline = "\n".data(using: .utf8)
  else { return }
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(newline)
}

private func writeError(_ message: String) {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
}

extension MidiEvent {
  fileprivate var json: [String: Any] {
    [
      "source": source,
      "sourceId": sourceID,
      "message": message,
      "channel": channel,
      "number": number,
      "value": value,
    ]
  }
}

extension HardwareCommand {
  fileprivate var keyDescription: String {
    switch self {
    case .hid(let key, _, _), .press(let key, _, _): return key
    case .joystick: return "joystick"
    }
  }
}
