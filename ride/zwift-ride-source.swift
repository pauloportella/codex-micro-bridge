import CoreBluetooth
import Foundation

private let rideService = CBUUID(string: "0000FC82-0000-1000-8000-00805F9B34FB")
private let legacyService = CBUUID(string: "00000001-19CA-4651-86E5-FA29DCDD09D1")
private let asyncCharacteristic = CBUUID(string: "00000002-19CA-4651-86E5-FA29DCDD09D1")
private let syncRxCharacteristic = CBUUID(string: "00000003-19CA-4651-86E5-FA29DCDD09D1")
private let syncTxCharacteristic = CBUUID(string: "00000004-19CA-4651-86E5-FA29DCDD09D1")
private let rideOn = Data([0x52, 0x69, 0x64, 0x65, 0x4f, 0x6e])
private let zwiftCompanyId: UInt16 = 0x094a
private let rideLeftType: UInt8 = 0x08
private let rideRightType: UInt8 = 0x07
private let controllerNotification: UInt8 = 0x23
private let analogThreshold = 25

private struct RideStatus {
    let buttonMap: UInt32
    let analog: [(location: Int, value: Int)]
}

private enum DecodeError: Error {
    case truncated
    case invalidWireType(UInt64)
    case overflow
}

private let digitalButtons: [(name: String, mask: UInt32)] = [
    ("navigationLeft", 0x00001),
    ("navigationUp", 0x00002),
    ("navigationRight", 0x00004),
    ("navigationDown", 0x00008),
    ("a", 0x00010),
    ("b", 0x00020),
    ("y", 0x00040),
    ("z", 0x00080),
    ("shiftUpLeft", 0x00100),
    ("shiftDownLeft", 0x00200),
    ("powerUpLeft", 0x00400),
    ("onOffLeft", 0x00800),
    ("shiftUpRight", 0x01000),
    ("shiftDownRight", 0x02000),
    ("powerUpRight", 0x04000),
    ("onOffRight", 0x08000),
]

private func writeJSON(_ value: [String: Any], to handle: FileHandle = .standardOutput) {
    guard let data = try? JSONSerialization.data(withJSONObject: value),
          let newline = "\n".data(using: .utf8) else { return }
    handle.write(data)
    handle.write(newline)
}

private func readVarint(_ bytes: [UInt8], _ index: inout Int) throws -> UInt64 {
    var value: UInt64 = 0
    var shift: UInt64 = 0
    while index < bytes.count && shift < 64 {
        let byte = bytes[index]
        index += 1
        value |= UInt64(byte & 0x7f) << shift
        if byte & 0x80 == 0 { return value }
        shift += 7
    }
    if shift >= 64 { throw DecodeError.overflow }
    throw DecodeError.truncated
}

private func skipField(wireType: UInt64, bytes: [UInt8], index: inout Int) throws {
    switch wireType {
    case 0:
        _ = try readVarint(bytes, &index)
    case 1:
        guard index + 8 <= bytes.count else { throw DecodeError.truncated }
        index += 8
    case 2:
        let length = Int(try readVarint(bytes, &index))
        guard index + length <= bytes.count else { throw DecodeError.truncated }
        index += length
    case 5:
        guard index + 4 <= bytes.count else { throw DecodeError.truncated }
        index += 4
    default:
        throw DecodeError.invalidWireType(wireType)
    }
}

private func decodeSigned32(_ encoded: UInt64) -> Int {
    let value = Int64(encoded >> 1) ^ -Int64(encoded & 1)
    return Int(Int32(truncatingIfNeeded: value))
}

private func parseAnalog(_ bytes: [UInt8]) throws -> (location: Int, value: Int) {
    var index = 0
    var location = 0
    var value = 0
    while index < bytes.count {
        let key = try readVarint(bytes, &index)
        let field = key >> 3
        let wire = key & 0x07
        if field == 1 && wire == 0 {
            location = Int(try readVarint(bytes, &index))
        } else if field == 2 && wire == 0 {
            value = decodeSigned32(try readVarint(bytes, &index))
        } else {
            try skipField(wireType: wire, bytes: bytes, index: &index)
        }
    }
    return (location, value)
}

private func parseRideStatus(_ bytes: [UInt8]) throws -> RideStatus {
    var index = 0
    var buttonMap: UInt32 = 0xffff_ffff
    var analog: [(location: Int, value: Int)] = []

    while index < bytes.count {
        let key = try readVarint(bytes, &index)
        let field = key >> 3
        let wire = key & 0x07
        if field == 1 && wire == 0 {
            buttonMap = UInt32(truncatingIfNeeded: try readVarint(bytes, &index))
        } else if field == 3 && wire == 2 {
            let length = Int(try readVarint(bytes, &index))
            guard index + length <= bytes.count else { throw DecodeError.truncated }
            analog.append(try parseAnalog(Array(bytes[index..<(index + length)])))
            index += length
        } else {
            try skipField(wireType: wire, bytes: bytes, index: &index)
        }
    }
    return RideStatus(buttonMap: buttonMap, analog: analog)
}

private func pressedButtons(in status: RideStatus) -> Set<String> {
    var pressed = Set(
        digitalButtons.compactMap { (status.buttonMap & $0.mask) == 0 ? $0.name : nil }
    )
    for paddle in status.analog where abs(paddle.value) >= analogThreshold {
        if paddle.location == 0 { pressed.insert("paddleLeft") }
        if paddle.location == 1 { pressed.insert("paddleRight") }
    }
    return pressed
}

private final class ZwiftRideReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var asyncInput: CBCharacteristic?
    private var syncInput: CBCharacteristic?
    private var syncOutput: CBCharacteristic?
    private var readyNotifications = Set<CBUUID>()
    private var handshakeSent = false
    private var pressed = Set<String>()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            writeJSON(["message": "status", "state": "scanning"])
            central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false,
            ])
        case .unauthorized:
            writeJSON(["message": "error", "error": "Bluetooth permission denied"])
            exit(2)
        case .unsupported:
            writeJSON(["message": "error", "error": "Bluetooth is not supported"])
            exit(2)
        case .poweredOff:
            writeJSON(["message": "status", "state": "bluetooth-off"])
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover candidate: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard peripheral == nil else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? candidate.name ?? ""
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasRideService = advertisedServices.contains(rideService) || advertisedServices.contains(legacyService)

        var controllerType: UInt8?
        if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           manufacturer.count >= 3 {
            let bytes = [UInt8](manufacturer)
            let company = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            if company == zwiftCompanyId { controllerType = bytes[2] }
        }

        if controllerType == rideRightType {
            writeJSON(["message": "status", "state": "found-right", "name": name])
            return
        }
        guard controllerType == rideLeftType || (name == "Zwift Ride" && hasRideService) else { return }

        peripheral = candidate
        candidate.delegate = self
        central.stopScan()
        writeJSON([
            "message": "status",
            "state": "connecting",
            "name": name,
            "id": candidate.identifier.uuidString,
            "rssi": RSSI.intValue,
        ])
        central.connect(candidate)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        writeJSON(["message": "status", "state": "connected", "name": peripheral.name ?? "Zwift Ride"])
        peripheral.discoverServices([rideService, legacyService])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        writeJSON(["message": "error", "error": error?.localizedDescription ?? "Connection failed"])
        restartScan()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        handleDisconnect(error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        handleDisconnect(error: error)
    }

    private func handleDisconnect(error: Error?) {
        releaseAllButtons()
        writeJSON([
            "message": "status",
            "state": "disconnected",
            "error": error?.localizedDescription ?? "",
        ])
        restartScan()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            writeJSON(["message": "error", "error": "Service discovery failed: \(error.localizedDescription)"])
            return
        }
        let services = peripheral.services ?? []
        guard let service = services.first(where: { $0.uuid == rideService || $0.uuid == legacyService }) else {
            writeJSON(["message": "error", "error": "Zwift controller service was not found"])
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics(
            [asyncCharacteristic, syncRxCharacteristic, syncTxCharacteristic],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            writeJSON(["message": "error", "error": "Characteristic discovery failed: \(error.localizedDescription)"])
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case asyncCharacteristic: asyncInput = characteristic
            case syncRxCharacteristic: syncOutput = characteristic
            case syncTxCharacteristic: syncInput = characteristic
            default: break
            }
        }
        guard let asyncInput, let syncInput, syncOutput != nil else {
            writeJSON(["message": "error", "error": "Zwift Ride characteristics were incomplete"])
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.setNotifyValue(true, for: asyncInput)
        peripheral.setNotifyValue(true, for: syncInput)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            writeJSON(["message": "error", "error": "Could not subscribe: \(error.localizedDescription)"])
            return
        }
        if characteristic.isNotifying { readyNotifications.insert(characteristic.uuid) }
        guard readyNotifications.contains(asyncCharacteristic),
              readyNotifications.contains(syncTxCharacteristic),
              !handshakeSent,
              let output = syncOutput else { return }

        let writeType: CBCharacteristicWriteType = output.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        peripheral.writeValue(rideOn, for: output, type: writeType)
        handshakeSent = true
        writeJSON(["message": "status", "state": "handshake-sent"])
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            writeJSON(["message": "error", "error": "Bluetooth update failed: \(error.localizedDescription)"])
            return
        }
        guard let value = characteristic.value else { return }
        if characteristic.uuid == syncTxCharacteristic {
            if value.starts(with: rideOn) {
                writeJSON(["message": "status", "state": "ready", "name": peripheral.name ?? "Zwift Ride"])
            }
            return
        }
        guard characteristic.uuid == asyncCharacteristic else { return }
        processNotification([UInt8](value))
    }

    private func processNotification(_ bytes: [UInt8]) {
        guard bytes.first == controllerNotification else { return }
        do {
            let status = try parseRideStatus(Array(bytes.dropFirst()))
            let current = pressedButtons(in: status)
            for button in current.subtracting(pressed).sorted() { emit(button: button, state: "down") }
            for button in pressed.subtracting(current).sorted() { emit(button: button, state: "up") }
            pressed = current
        } catch {
            writeJSON(["message": "error", "error": "Invalid Zwift Ride packet: \(error)"])
        }
    }

    private func emit(button: String, state: String) {
        writeJSON([
            "message": "button",
            "source": peripheral?.name ?? "Zwift Ride",
            "button": button,
            "state": state,
        ])
    }

    private func releaseAllButtons() {
        for button in pressed.sorted() { emit(button: button, state: "up") }
        pressed.removeAll()
    }

    private func restartScan() {
        self.peripheral = nil
        asyncInput = nil
        syncInput = nil
        syncOutput = nil
        readyNotifications.removeAll()
        handshakeSent = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard self.central.state == .poweredOn else { return }
            writeJSON(["message": "status", "state": "scanning"])
            self.central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false,
            ])
        }
    }
}

private func runSelfTest() throws {
    let released = try parseRideStatus([0x08, 0xff, 0xff, 0xff, 0xff, 0x0f])
    precondition(pressedButtons(in: released).isEmpty)

    let leftPressed = try parseRideStatus([0x08, 0xfe, 0xff, 0xff, 0xff, 0x0f])
    precondition(pressedButtons(in: leftPressed) == ["navigationLeft"])

    let paddle = try parseRideStatus([
        0x08, 0xff, 0xff, 0xff, 0xff, 0x0f,
        0x1a, 0x02, 0x10, 0x3c,
    ])
    precondition(pressedButtons(in: paddle) == ["paddleLeft"])
    print("Zwift Ride decoder self-test passed")
}

if CommandLine.arguments.contains("--self-test") {
    do {
        try runSelfTest()
        exit(0)
    } catch {
        fputs("Self-test failed: \(error)\n", stderr)
        exit(1)
    }
}

private let reader = ZwiftRideReader()
withExtendedLifetime(reader) {
    RunLoop.main.run()
}
