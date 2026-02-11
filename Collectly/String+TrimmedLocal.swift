//
//  String+TrimmedLocal.swift
//  Collectly
//
//  Shared helpers
//

import Foundation

extension String {
    /// Trims whitespaces + newlines (project-wide helper).
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Backward-compatible alias (if some files still use trimmedLocal).
    var trimmedLocal: String { trimmed }

    /// Returns nil if the trimmed string is empty.
    var nonEmptyOrNil: String? {
        let t = trimmed
        return t.isEmpty ? nil : t
    }
}
