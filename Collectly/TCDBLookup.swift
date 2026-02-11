import Foundation

// MARK: - TCDB Lookup
// Permet de valider/corriger les infos OCR/eBay avec la base TCDB

enum TCDBLookup {
    
    // MARK: - Data structures
    
    private struct TCDBData: Codable {
        let sets: [String: TCDBSet]
        let aliases: [String: String]
    }
    
    private struct TCDBSet: Codable {
        let tcdb_id: Int
        let cards: [String: String]  // number -> player
    }
    
    // MARK: - Cached data
    
    private static var data: TCDBData? = {
        guard let url = Bundle.main.url(forResource: "tcdb_sets", withExtension: "json"),
              let jsonData = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TCDBData.self, from: jsonData) else {
            print("⚠️ TCDBLookup: tcdb_sets.json not found in bundle")
            return nil
        }
        print("✅ TCDBLookup: loaded \(decoded.sets.count) sets")
        return decoded
    }()
    
    // MARK: - Public API
    
    /// Lookup player name from set + card number
    /// - Parameters:
    ///   - set: Set name (e.g., "2024-25 Upper Deck")
    ///   - number: Card number (e.g., "207", "FWA-3")
    /// - Returns: Canonical player name if found
    static func playerName(set: String, number: String) -> String? {
        guard let data = data else { return nil }
        
        let normalizedSet = resolveSetAlias(set)
        guard let setData = data.sets[normalizedSet] else { return nil }
        
        let normalizedNumber = normalizeCardNumber(number)
        return setData.cards[normalizedNumber]
    }
    
    /// Lookup player with confidence score
    /// Returns (playerName, confidence) where confidence is 1.0 for TCDB match
    static func playerNameWithConfidence(
        set: String,
        number: String,
        ebayCandidate: String? = nil,
        ebayConfidence: Double? = nil
    ) -> (name: String, confidence: Double, source: String)? {
        
        // Try TCDB first (highest confidence)
        if let tcdbName = playerName(set: set, number: number) {
            // If eBay also suggested the same name, even higher confidence
            if let ebay = ebayCandidate,
               namesMatch(tcdbName, ebay) {
                return (tcdbName, 1.0, "TCDB+eBay")
            }
            return (tcdbName, 0.95, "TCDB")
        }
        
        // Fallback to eBay
        if let ebay = ebayCandidate, let conf = ebayConfidence {
            return (ebay, conf, "eBay")
        }
        
        return nil
    }
    
    /// Check if TCDB has data for a specific set
    static func hasSet(_ setName: String) -> Bool {
        guard let data = data else { return false }
        let normalized = resolveSetAlias(setName)
        return data.sets[normalized] != nil
    }
    
    /// Get all known set names
    static func knownSets() -> [String] {
        data?.sets.keys.sorted() ?? []
    }
    
    // MARK: - Helpers
    
    private static func resolveSetAlias(_ input: String) -> String {
        let lower = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return data?.aliases[lower] ?? input
    }
    
    private static func normalizeCardNumber(_ num: String) -> String {
        var n = num.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove leading #
        if n.hasPrefix("#") { n = String(n.dropFirst()) }
        return n
    }
    
    private static func namesMatch(_ a: String, _ b: String) -> Bool {
        let normalize: (String) -> String = { s in
            s.lowercased()
             .folding(options: .diacriticInsensitive, locale: .current)
             .replacingOccurrences(of: "[^a-z ]", with: "", options: .regularExpression)
             .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
             .trimmingCharacters(in: .whitespaces)
        }
        return normalize(a) == normalize(b)
    }
}

// MARK: - Integration with existing flow

extension TCDBLookup {
    
    /// Enhanced player name resolution combining OCR + eBay + TCDB
    /// Priority: TCDB (validated) > eBay+TCDB match > eBay alone > OCR
    static func resolvePlayerName(
        ocrName: String?,
        ebayName: String?,
        ebayConfidence: Double?,
        year: String?,
        company: String?,
        setName: String?,
        cardNumber: String?
    ) -> (name: String, confidence: Double, source: String)? {
        
        // Build set identifier from year + company
        let setKey: String? = {
            guard let y = year?.trimmingCharacters(in: .whitespaces),
                  let c = company?.trimmingCharacters(in: .whitespaces),
                  !y.isEmpty, !c.isEmpty else { return setName }
            return "\(y) \(c)"
        }()
        
        // Try TCDB lookup if we have set + number
        if let set = setKey, let num = cardNumber, !num.isEmpty {
            if let result = playerNameWithConfidence(
                set: set,
                number: num,
                ebayCandidate: ebayName,
                ebayConfidence: ebayConfidence
            ) {
                return result
            }
        }
        
        // Fallback to eBay
        if let ebay = ebayName, let conf = ebayConfidence, conf >= 0.5 {
            return (ebay, conf, "eBay")
        }
        
        // Fallback to OCR
        if let ocr = ocrName, !ocr.isEmpty {
            return (ocr, 0.3, "OCR")
        }
        
        return nil
    }
}
