import CryptoKit
import Foundation

/// Stable audit references for user/agent identity text. Audit rows should prove
/// that the same value was involved without storing the raw goal, name, path, or label.
public enum AuditIdentity {
    public static func hash(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        return SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public static func count(_ value: String?) -> Int {
        value?.count ?? 0
    }

    public static func descriptor(_ field: String, _ value: String?) -> String {
        "\(field)Hash=\(hash(value)) \(field)Chars=\(count(value))"
    }

    public static func safeToken(_ value: String) -> String {
        let token = value.filter { character in
            character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
        }
        return token.isEmpty ? "unknown" : token
    }
}
