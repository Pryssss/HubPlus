import Foundation
import Security

/// Reads the Claude Code OAuth access token from the macOS Keychain.
///
/// The token is read-only: it is returned to the caller for a single request to
/// Anthropic and is never logged, persisted, or copied anywhere by Hub+. The first
/// read of this foreign Keychain item prompts the user to allow access (expected).
enum KeychainReader {
    private static let service = "Claude Code-credentials"

    static func claudeCodeToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }

        // The stored value is a JSON blob; the token lives at some `accessToken` key.
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let token = findToken(in: obj) {
            return token
        }
        // Fallback: a bare token string (not JSON).
        if let s = String(data: data, encoding: .utf8), !s.hasPrefix("{"), s.count > 20 {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func findToken(in obj: Any) -> String? {
        guard let dict = obj as? [String: Any] else { return nil }
        for key in ["accessToken", "access_token"] {
            if let t = dict[key] as? String, !t.isEmpty { return t }
        }
        for value in dict.values {
            if let t = findToken(in: value) { return t }
        }
        return nil
    }
}
