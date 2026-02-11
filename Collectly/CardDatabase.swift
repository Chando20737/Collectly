import Foundation

// ============================================================================
// CardDatabase.swift — Lookup local pour Cardia
// ============================================================================
//
// Ce fichier montre comment intégrer la base de données scrapée
// dans ton app iOS pour faire des lookups instantanés.
//
// Usage:
// 1. Exporte cards_database.json depuis le scraper Python
// 2. Ajoute le fichier JSON dans ton bundle Xcode
// 3. Utilise CardDatabase.shared.search(...)
// ============================================================================

// MARK: - Models

struct CardDatabaseEntry: Codable, Identifiable {
    let id: String
    let year: String
    let company: String
    let set: String
    let subset: String?
    let number: String
    let player: String
    let team: String?
    
    // Pour la recherche fuzzy
    var searchableText: String {
        [player, team ?? "", set, number, year]
            .joined(separator: " ")
            .lowercased()
    }
}

struct CardDatabaseFile: Codable {
    let version: String
    let generatedAt: String
    let totalCards: Int
    let cards: [CardDatabaseEntry]
    
    enum CodingKeys: String, CodingKey {
        case version
        case generatedAt = "generated_at"
        case totalCards = "total_cards"
        case cards
    }
}

// MARK: - Database Manager

final class CardDatabase {
    
    static let shared = CardDatabase()
    
    private var cards: [CardDatabaseEntry] = []
    private var byNumber: [String: [CardDatabaseEntry]] = [:]
    private var byPlayer: [String: [CardDatabaseEntry]] = [:]
    
    var isLoaded: Bool { !cards.isEmpty }
    var totalCards: Int { cards.count }
    
    private init() {
        loadFromBundle()
    }
    
    // MARK: - Loading
    
    func loadFromBundle(filename: String = "cards_database") {
        guard let url = Bundle.main.url(forResource: filename, withExtension: "json") else {
            print("⚠️ CardDatabase: \(filename).json not found in bundle")
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(CardDatabaseFile.self, from: data)
            
            self.cards = decoded.cards
            buildIndexes()
            
            print("✅ CardDatabase loaded: \(cards.count) cards")
        } catch {
            print("❌ CardDatabase load error: \(error)")
        }
    }
    
    private func buildIndexes() {
        // Index par numéro de carte
        byNumber = Dictionary(grouping: cards) { entry in
            normalizeNumber(entry.number)
        }
        
        // Index par nom de joueur (normalisé)
        byPlayer = Dictionary(grouping: cards) { entry in
            normalizePlayerName(entry.player)
        }
    }
    
    // MARK: - Search
    
    /// Recherche par numéro de carte (ex: "201", "#201", "YG-1")
    func searchByNumber(_ number: String, year: String? = nil, set: String? = nil) -> [CardDatabaseEntry] {
        let normalized = normalizeNumber(number)
        var results = byNumber[normalized] ?? []
        
        // Filtrer par année si spécifiée
        if let year = year {
            results = results.filter { $0.year.contains(year) || year.contains($0.year) }
        }
        
        // Filtrer par set si spécifié
        if let set = set {
            let setLower = set.lowercased()
            results = results.filter { $0.set.lowercased().contains(setLower) }
        }
        
        return results
    }
    
    /// Recherche par nom de joueur (fuzzy)
    func searchByPlayer(_ name: String) -> [CardDatabaseEntry] {
        let normalized = normalizePlayerName(name)
        
        // Exact match d'abord
        if let exact = byPlayer[normalized] {
            return exact
        }
        
        // Fuzzy match: cherche les noms qui contiennent le terme
        let results = cards.filter { entry in
            let entryName = normalizePlayerName(entry.player)
            return entryName.contains(normalized) || normalized.contains(entryName)
        }
        
        return results
    }
    
    /// Recherche combinée (OCR input typique)
    /// Prend les infos détectées par OCR et trouve la meilleure correspondance
    func search(
        playerName: String? = nil,
        cardNumber: String? = nil,
        year: String? = nil,
        company: String? = nil,
        setName: String? = nil
    ) -> [CardDatabaseEntry] {
        
        var results = cards
        
        // Filtre par année
        if let year = year, !year.isEmpty {
            let yearNorm = year.replacingOccurrences(of: "-", with: "")
            results = results.filter { entry in
                let entryYear = entry.year.replacingOccurrences(of: "-", with: "")
                return entryYear.contains(yearNorm) || yearNorm.contains(entryYear)
            }
        }
        
        // Filtre par compagnie
        if let company = company, !company.isEmpty {
            let compLower = company.lowercased()
            results = results.filter { $0.company.lowercased().contains(compLower) }
        }
        
        // Filtre par set
        if let setName = setName, !setName.isEmpty {
            let setLower = setName.lowercased()
            results = results.filter { entry in
                entry.set.lowercased().contains(setLower) ||
                (entry.subset?.lowercased().contains(setLower) ?? false)
            }
        }
        
        // Filtre par numéro (le plus précis)
        if let cardNumber = cardNumber, !cardNumber.isEmpty {
            let numNorm = normalizeNumber(cardNumber)
            let filtered = results.filter { normalizeNumber($0.number) == numNorm }
            if !filtered.isEmpty {
                results = filtered
            }
        }
        
        // Filtre par joueur (fuzzy)
        if let playerName = playerName, !playerName.isEmpty {
            let nameNorm = normalizePlayerName(playerName)
            let filtered = results.filter { entry in
                let entryName = normalizePlayerName(entry.player)
                return entryName.contains(nameNorm) || 
                       nameNorm.contains(entryName) ||
                       fuzzyMatch(entryName, nameNorm)
            }
            if !filtered.isEmpty {
                results = filtered
            }
        }
        
        // Trier par pertinence (priorité au match exact sur numéro)
        if let cardNumber = cardNumber {
            let numNorm = normalizeNumber(cardNumber)
            results.sort { a, b in
                let aExact = normalizeNumber(a.number) == numNorm
                let bExact = normalizeNumber(b.number) == numNorm
                if aExact != bExact { return aExact }
                return a.year > b.year // Plus récent d'abord
            }
        }
        
        return Array(results.prefix(10)) // Max 10 résultats
    }
    
    /// Recherche rapide pour l'autocomplétion
    func quickSearch(_ query: String, limit: Int = 5) -> [CardDatabaseEntry] {
        guard query.count >= 2 else { return [] }
        
        let queryLower = query.lowercased()
        
        return cards
            .filter { $0.searchableText.contains(queryLower) }
            .prefix(limit)
            .map { $0 }
    }
    
    // MARK: - Normalization
    
    private func normalizeNumber(_ raw: String) -> String {
        // "#201" → "201", "YG-1" → "yg-1"
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
    
    private func normalizePlayerName(_ raw: String) -> String {
        // "Macklin Celebrini" → "macklincelebrini"
        raw.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "'", with: "")
    }
    
    private func fuzzyMatch(_ a: String, _ b: String) -> Bool {
        // Simple: vérifie si le nom de famille match
        let aTokens = a.split(separator: " ").map(String.init)
        let bTokens = b.split(separator: " ").map(String.init)
        
        // Si un des tokens matche complètement
        for aToken in aTokens {
            for bToken in bTokens {
                if aToken == bToken && aToken.count >= 4 {
                    return true
                }
            }
        }
        
        return false
    }
}

// MARK: - Integration avec ton OCR existant

extension CardDatabase {
    
    /// Appelé après l'OCR pour enrichir les champs automatiquement
    /// Retourne les champs suggérés basés sur la DB locale
    func suggestFromOCR(
        ocrPlayerName: String?,
        ocrYear: String?,
        ocrCompany: String?,
        ocrSetName: String?,
        ocrCardNumber: String?
    ) -> (
        playerName: String?,
        year: String?,
        company: String?,
        setName: String?,
        cardNumber: String?,
        confidence: Double
    ) {
        let results = search(
            playerName: ocrPlayerName,
            cardNumber: ocrCardNumber,
            year: ocrYear,
            company: ocrCompany,
            setName: ocrSetName
        )
        
        guard let best = results.first else {
            // Aucun match — retourne les valeurs OCR telles quelles
            return (ocrPlayerName, ocrYear, ocrCompany, ocrSetName, ocrCardNumber, 0.0)
        }
        
        // Calcule la confiance basée sur combien de champs matchent
        var matchCount = 0
        var totalFields = 0
        
        if ocrCardNumber != nil {
            totalFields += 1
            if normalizeNumber(best.number) == normalizeNumber(ocrCardNumber!) {
                matchCount += 1
            }
        }
        
        if ocrYear != nil {
            totalFields += 1
            if best.year.contains(ocrYear!) || ocrYear!.contains(best.year) {
                matchCount += 1
            }
        }
        
        if ocrPlayerName != nil {
            totalFields += 1
            let nameMatch = normalizePlayerName(best.player).contains(normalizePlayerName(ocrPlayerName!))
            if nameMatch { matchCount += 1 }
        }
        
        let confidence = totalFields > 0 ? Double(matchCount) / Double(totalFields) : 0.5
        
        return (
            playerName: best.player,
            year: best.year,
            company: best.company,
            setName: best.subset ?? best.set,
            cardNumber: best.number,
            confidence: confidence
        )
    }
}

// MARK: - Usage Example

/*
 
 // Dans CVPhotoOCRAddCardView.swift, après l'OCR:
 
 func handleFront(_ img: UIImage) {
     // ... ton code OCR existant ...
     
     // NOUVEAU: Lookup local AVANT eBay
     if CardDatabase.shared.isLoaded {
         let suggestion = CardDatabase.shared.suggestFromOCR(
             ocrPlayerName: playerName,
             ocrYear: cardYear,
             ocrCompany: companyName,
             ocrSetName: setName,
             ocrCardNumber: cardNumber
         )
         
         if suggestion.confidence > 0.6 {
             // Match local trouvé — utilise les données de la DB
             playerName = suggestion.playerName ?? playerName
             cardYear = suggestion.year ?? cardYear
             companyName = suggestion.company ?? companyName
             setName = suggestion.setName ?? setName
             cardNumber = suggestion.cardNumber ?? cardNumber
             
             // Skip eBay lookup — on a déjà un bon match
             return
         }
     }
     
     // Fallback: eBay lookup (ton code existant)
     await tryEbayAutofillPlayerName(forceOverride: false)
 }
 
 */
