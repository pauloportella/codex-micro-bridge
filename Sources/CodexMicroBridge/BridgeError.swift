import Foundation

public struct BridgeError: Error, LocalizedError, CustomStringConvertible {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }

  public var errorDescription: String? { message }
  public var description: String { message }
}
