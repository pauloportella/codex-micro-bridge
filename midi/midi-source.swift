import CoreMIDI
import Foundation

struct SourceDescription {
    let endpoint: MIDIEndpointRef
    let id: Int32
    let name: String
    let manufacturer: String
    let model: String

    var json: [String: Any] {
        [
            "id": id,
            "name": name,
            "manufacturer": manufacturer,
            "model": model,
        ]
    }
}

final class SourceContext {
    let source: SourceDescription
    private var runningStatus: UInt8?
    private var dataBytes: [UInt8] = []

    init(source: SourceDescription) {
        self.source = source
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
                writeJSONLine([
                    "source": source.name,
                    "sourceId": source.id,
                    "message": message,
                    "channel": Int(statusByte & 0x0f) + 1,
                    "number": Int(dataBytes[0]),
                    "value": Int(dataBytes[1]),
                ])
            }
            dataBytes.removeAll(keepingCapacity: true)
        }
    }
}

func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, property, &value) == noErr,
          let value
    else {
        return ""
    }
    return value.takeRetainedValue() as String
}

func integerProperty(_ object: MIDIObjectRef, _ property: CFString) -> Int32 {
    var value: Int32 = 0
    _ = MIDIObjectGetIntegerProperty(object, property, &value)
    return value
}

func availableSources() -> [SourceDescription] {
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

func writeJSONLine(_ value: Any, to handle: FileHandle = .standardOutput) {
    guard let data = try? JSONSerialization.data(withJSONObject: value),
          let newline = "\n".data(using: .utf8)
    else {
        return
    }
    handle.write(data)
    handle.write(newline)
}

func argument(after name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1)
    else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

let allSources = availableSources()

if CommandLine.arguments.contains("--list") {
    writeJSONLine(allSources.map(\.json))
    exit(EXIT_SUCCESS)
}

let deviceFilter = argument(after: "--device")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
let selectedSources = allSources.filter { source in
    deviceFilter.isEmpty || [source.name, source.manufacturer, source.model]
        .joined(separator: " ")
        .localizedCaseInsensitiveContains(deviceFilter)
}

guard !selectedSources.isEmpty else {
    let available = allSources.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
    FileHandle.standardError.write(
        Data("No matching MIDI input. Available inputs: \(available.isEmpty ? "none" : available)\n".utf8)
    )
    exit(EXIT_FAILURE)
}

var client = MIDIClientRef()
var inputPort = MIDIPortRef()
let clientStatus = MIDIClientCreateWithBlock("Codex Micro MIDI Bridge" as CFString, &client) { _ in }
guard clientStatus == noErr else {
    FileHandle.standardError.write(Data("MIDIClientCreate failed: \(clientStatus)\n".utf8))
    exit(EXIT_FAILURE)
}

let portStatus = MIDIInputPortCreate(
    client,
    "Codex Micro Input" as CFString,
    { packetListPointer, _, sourceConnectionRefCon in
    guard let sourceConnectionRefCon else { return }
    let context = Unmanaged<SourceContext>.fromOpaque(sourceConnectionRefCon).takeUnretainedValue()
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
    FileHandle.standardError.write(Data("MIDIInputPortCreate failed: \(portStatus)\n".utf8))
    exit(EXIT_FAILURE)
}

var retainedContexts: [Unmanaged<SourceContext>] = []
for source in selectedSources {
    let retained = Unmanaged.passRetained(SourceContext(source: source))
    let status = MIDIPortConnectSource(inputPort, source.endpoint, retained.toOpaque())
    if status == noErr {
        retainedContexts.append(retained)
        FileHandle.standardError.write(Data("Listening to MIDI input: \(source.name)\n".utf8))
    } else {
        retained.release()
        FileHandle.standardError.write(Data("Could not connect MIDI input \(source.name): \(status)\n".utf8))
    }
}

guard !retainedContexts.isEmpty else {
    exit(EXIT_FAILURE)
}

RunLoop.current.run()
