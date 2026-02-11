//  CardBadges.swift
//  Collectly
//
//  Smart badges (Auto + Manual) for CardItem
//  - Auto: inferred from title/notes/set/company/number
//  - Manual: user toggles in EditCardView
//
//  Badge mode:
//    - auto: show only auto
//    - mix: union(auto, manual)
//    - manual: show only manual
//
//  Storage in CardItem:
//    - badgeModeRaw: "auto" | "mix" | "manual" (default "mix")
//    - manualBadgesRaw: comma-separated raw values (e.g. "rookie,autograph")
//
import Foundation

enum CardBadge: String, CaseIterable, Identifiable, Codable {
    case rookie
    case patch
    case autograph
    case numbered
    case graded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rookie: return "Rookie"
        case .patch: return "Patch"
        case .autograph: return "Autographié"
        case .numbered: return "Numéroté"
        case .graded: return "Gradée"
        }
    }

    var systemImage: String {
        switch self {
        case .rookie: return "sparkles"
        case .patch: return "square.on.square"
        case .autograph: return "pencil.and.outline"
        case .numbered: return "number"
        case .graded: return "checkmark.seal"
        }
    }
}

enum CardBadgeMode: String, CaseIterable, Identifiable {
    case auto
    case mix
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .mix: return "Auto + manuel"
        case .manual: return "Manuel"
        }
    }
}

struct CardBadgesEngine {

    static func effectiveBadges(
        title: String,
        notes: String?,
        setName: String?,
        companyName: String?,
        cardNumber: String?,
        isGraded: Bool?,
        badgeModeRaw: String?,
        manualBadgesRaw: String?,
        disabledBadgesRaw: String?
    ) -> [CardBadge] {

        let mode = CardBadgeMode(rawValue: (badgeModeRaw ?? "").lowercased()) ?? .mix

        let auto = autoBadges(
            title: title,
            notes: notes,
            setName: setName,
            companyName: companyName,
            cardNumber: cardNumber,
            isGraded: isGraded
        )

        let manual = parseManualBadges(manualBadgesRaw)
        let disabled = parseManualBadges(disabledBadgesRaw)

        let final: Set<CardBadge>
        switch mode {
        case .auto:
            final = auto.subtracting(disabled)
        case .manual:
            final = manual
        case .mix:
            final = auto.union(manual).subtracting(disabled)
        }

        return sortBadges(Array(final))
    }

    static func autoBadges(
        title: String,
        notes: String?,
        setName: String?,
        companyName: String?,
        cardNumber: String?,
        isGraded: Bool?
    ) -> Set<CardBadge> {

        let blob = [
            title,
            notes ?? "",
            setName ?? "",
            companyName ?? "",
            cardNumber ?? ""
        ].joined(separator: " ").lowercased()

        var out: Set<CardBadge> = []

        // Rookie detection (safe, hobby-focused)
        // - "young guns" is strongly rookie; "future watch" often rookie too
        if containsAny(blob, [
            "rookie", "rc", "young guns", "youngguns", "yg", "future watch", "fwa"
        ]) {
            out.insert(.rookie)
        }

        // Autograph
        if containsAny(blob, [
            "auto", "autograph", "autographed", "signature", "signed", "on-card", "on card"
        ]) {
            out.insert(.autograph)
        }

        // Patch / Jersey / Relic / Game Used
        // NOTE: we avoid naive substring checks like "gu" because it matches "guns" (Young Guns).
        // Use word-boundary regex for short tokens.
        let patchPatterns = [
            #"\bpatch\b"#,
            #"\bjersey\b"#,
            #"\bswatch\b"#,
            #"\brelic\b"#,
            #"\bmemorabilia\b"#,
            #"\bgame\s*used\b"#,
            #"\bgame-used\b"#,
            #"\bgu\b"#
        ]
        if matchesAnyRegex(blob, patchPatterns) {
            out.insert(.patch)
        }

        // Numbered (e.g., 12/99, /199, 001/999)
        if isNumberedText(blob) {
            out.insert(.numbered)
        }

        // Graded
        if isGraded == true {
            out.insert(.graded)
        }

        return out
    }

    static func parseManualBadges(_ raw: String?) -> Set<CardBadge> {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let parts = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        var out: Set<CardBadge> = []
        for p in parts {
            if let b = CardBadge(rawValue: p) { out.insert(b) }
        }
        return out
    }

    static func encodeManualBadges(_ badges: Set<CardBadge>) -> String {
        badges.map { $0.rawValue }.sorted().joined(separator: ",")
    }

    static func sortBadges(_ badges: [CardBadge]) -> [CardBadge] {
        // Priority order (most "valuable" first)
        let order: [CardBadge] = [.rookie, .autograph, .patch, .numbered, .graded]
        return badges.sorted {
            (order.firstIndex(of: $0) ?? 999) < (order.firstIndex(of: $1) ?? 999)
        }
    }

    private static func containsAny(_ blob: String, _ needles: [String]) -> Bool {
        for n in needles {
            if blob.contains(n) { return true }
        }
        return false
    }


private static func matchesAnyRegex(_ blob: String, _ patterns: [String]) -> Bool {
    for p in patterns {
        if blob.range(of: p, options: .regularExpression) != nil {
            return true
        }
    }
    return false
}

    private static func isNumberedText(_ blob: String) -> Bool {
        // Common patterns:
        // - "12/99" or "12 / 99"
        // - "/99" (less strict but common)
        // - "#12/99"
        // We'll require at least one digit after slash, and (optionally) digits before slash.
        let patterns = [
            #"\b\d{1,4}\s*/\s*\d{2,5}\b"#,
            #"/\s*\d{2,5}\b"#,
            #"\b\d{1,4}\s*of\s*\d{2,5}\b"#  // "12 of 99"
        ]
        for p in patterns {
            if blob.range(of: p, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
}
