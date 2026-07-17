import Foundation

public enum RideProtocolDecoder {
  private static let digitalButtons: [(name: String, mask: UInt32)] = [
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

  public static func pressedButtons(
    in bytes: [UInt8],
    analogThreshold: Int = 25
  ) throws -> Set<String> {
    let status = try parseStatus(bytes)
    var pressed = Set(
      digitalButtons.compactMap { (status.buttonMap & $0.mask) == 0 ? $0.name : nil }
    )
    for paddle in status.analog where abs(paddle.value) >= analogThreshold {
      if paddle.location == 0 { pressed.insert("paddleLeft") }
      if paddle.location == 1 { pressed.insert("paddleRight") }
    }
    return pressed
  }

  private static func parseStatus(_ bytes: [UInt8]) throws -> RideStatus {
    var index = 0
    var buttonMap: UInt32 = 0xffff_ffff
    var analog: [(location: Int, value: Int)] = []

    while index < bytes.count {
      let key = try readVarint(bytes, &index)
      let field = key >> 3
      let wire = key & 0x07
      if field == 1, wire == 0 {
        buttonMap = UInt32(truncatingIfNeeded: try readVarint(bytes, &index))
      } else if field == 3, wire == 2 {
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

  private static func parseAnalog(_ bytes: [UInt8]) throws -> (location: Int, value: Int) {
    var index = 0
    var location = 0
    var value = 0
    while index < bytes.count {
      let key = try readVarint(bytes, &index)
      let field = key >> 3
      let wire = key & 0x07
      if field == 1, wire == 0 {
        location = Int(try readVarint(bytes, &index))
      } else if field == 2, wire == 0 {
        value = decodeSigned32(try readVarint(bytes, &index))
      } else {
        try skipField(wireType: wire, bytes: bytes, index: &index)
      }
    }
    return (location, value)
  }

  private static func readVarint(_ bytes: [UInt8], _ index: inout Int) throws -> UInt64 {
    var value: UInt64 = 0
    var shift: UInt64 = 0
    while index < bytes.count, shift < 64 {
      let byte = bytes[index]
      index += 1
      value |= UInt64(byte & 0x7f) << shift
      if byte & 0x80 == 0 { return value }
      shift += 7
    }
    if shift >= 64 { throw DecodeError.overflow }
    throw DecodeError.truncated
  }

  private static func skipField(wireType: UInt64, bytes: [UInt8], index: inout Int) throws {
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

  private static func decodeSigned32(_ encoded: UInt64) -> Int {
    let value = Int64(encoded >> 1) ^ -Int64(encoded & 1)
    return Int(Int32(truncatingIfNeeded: value))
  }
}

private struct RideStatus {
  let buttonMap: UInt32
  let analog: [(location: Int, value: Int)]
}

private enum DecodeError: Error {
  case truncated
  case invalidWireType(UInt64)
  case overflow
}
