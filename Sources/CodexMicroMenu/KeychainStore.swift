import Foundation
import Security

enum KeychainStoreError: LocalizedError {
  case unexpectedStatus(OSStatus)
  case invalidData

  var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      return "Keychain operation failed (\(status))."
    case .invalidData:
      return "The saved API key could not be read."
    }
  }
}

final class APIKeyStore {
  private let service = "com.pauloportella.codex-micro-bridge"
  private let account = "openai-api-key"

  func load() throws -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
    guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.invalidData
    }
    return value
  }

  func save(_ value: String) throws {
    let data = Data(value.utf8)
    let status = SecItemUpdate(
      baseQuery as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if status == errSecItemNotFound {
      var item = baseQuery
      item[kSecValueData as String] = data
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw KeychainStoreError.unexpectedStatus(addStatus)
      }
      return
    }
    guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
  }

  func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainStoreError.unexpectedStatus(status)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
  }
}
