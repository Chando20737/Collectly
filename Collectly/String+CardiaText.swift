import Foundation

// Shared text helpers used across Cardia/Collectly
extension String {
    /// Returns a clean value or an em dash (—) when empty.
    /// NOTE: We intentionally do NOT define `trimmedLocal` here because it already exists elsewhere
    /// in the project. Keeping it duplicated causes "Invalid redeclaration of 'trimmedLocal'".
    var cleanOrDash: String {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "—" : t
    }
}

extension Optional where Wrapped == String {
    /// Returns a clean value or an em dash (—) when nil/empty.
    var cleanOrDash: String {
        let t = (self ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "—" : t
    }
}
