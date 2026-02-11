import Foundation
import UIKit

/// eBay Image Search - Recherche de cartes par image avec fallback OCR et choix multiple
struct EbayImageSearch {
    
    // MARK: - Configuration
    
    /// Récupère les credentials depuis Info.plist (comme le reste de l'app)
    private static var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "EBAY_CLIENT_ID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    
    private static var clientSecret: String {
        (Bundle.main.object(forInfoDictionaryKey: "EBAY_CLIENT_SECRET") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    
    private static var marketplaceID: String {
        // ⚠️ IMPORTANT: L'eBay Browse API (Image Search) ne supporte PAS EBAY-CA
        // Marketplaces supportés: EBAY-US, EBAY-GB, EBAY-DE, EBAY-AU
        // On force EBAY-US qui a le plus de cartes de hockey nord-américaines
        return "EBAY-US"
    }
    
    // MARK: - NHL Teams & Words to Ignore
    
    /// Équipes NHL et mots à ne JAMAIS considérer comme des noms de joueurs
    private static let nhlTeamsAndBadWords: Set<String> = [
        // Équipes NHL (noms complets et partiels)
        "canadiens", "habs", "montreal", "montréal",
        "maple", "leafs", "toronto",
        "bruins", "boston",
        "rangers", "islanders", "devils",
        "flyers", "philadelphia",
        "penguins", "pittsburgh",
        "capitals", "washington",
        "hurricanes", "carolina",
        "panthers", "florida",
        "lightning", "tampa",
        "red", "wings", "detroit",
        "blackhawks", "chicago",
        "blues", "louis",
        "wild", "minnesota",
        "stars", "dallas",
        "avalanche", "colorado",
        "coyotes", "arizona", "utah",
        "ducks", "anaheim",
        "kings", "angeles",
        "sharks", "jose",
        "kraken", "seattle",
        "knights", "vegas", "golden",
        "canucks", "vancouver",
        "flames", "calgary",
        "oilers", "edmonton",
        "jets", "winnipeg",
        "senators", "ottawa",
        "sabres", "buffalo",
        "jackets", "columbus",
        "predators", "nashville",
        
        // Mots de sets/cartes à ignorer
        "young", "guns", "series", "upper", "deck", "topps", "panini",
        "rookie", "rookies", "card", "hockey", "nhl", "update", "extended",
        "canvas", "exclusives", "parallel", "insert", "base",
        "tim", "hortons", "parkhurst", "artifacts", "premier",
        "black", "diamond", "opee", "chee", "pee",
        "game", "used", "authentic", "autographs", "auto", "sp", "rc",
        "patch", "jersey", "memorabilia", "signature", "signed",
        
        // Couleurs qui ne sont JAMAIS des noms (bloquées partout)
        "blue", "gold", "silver", "purple", "orange", "pink",
        "yellow", "clear", "ice", "rainbow",
        
        // Autres mots courants
        "new", "york", "bay", "san", "los", "st"
    ]
    
    // Couleurs qui PEUVENT être des noms de famille (Green, White, Red)
    // Ne bloquer que si c'est le PREMIER mot
    private static let colorsOnlyBadAsFirstName: Set<String> = [
        "green", "white", "red"
    ]
    
    // MARK: - Token Management
    
    /// Cache simple pour éviter de régénérer le token à chaque appel
    private static var cachedToken: (token: String, expiry: Date)?
    
    /// Génère automatiquement un nouveau token OAuth (Client Credentials flow)
    private static func getAccessToken() async throws -> String {
        // Vérifier le cache (les tokens eBay durent ~2h, on garde 1h45 pour être sûr)
        if let cached = cachedToken, cached.expiry > Date() {
            return cached.token
        }
        
        // Vérifier que les credentials sont configurés
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            throw NSError(
                domain: "EbayImageSearch",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "EBAY_CLIENT_ID et EBAY_CLIENT_SECRET manquants dans Info.plist"]
            )
        }
        
        // Préparer la requête OAuth
        let credentials = "\(clientID):\(clientSecret)"
        guard let credData = credentials.data(using: .utf8) else {
            throw NSError(
                domain: "EbayImageSearch",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode credentials"]
            )
        }
        
        let tokenURL = URL(string: "https://api.ebay.com/identity/v1/oauth2/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        // Scope pour la recherche d'images (read-only)
        let scope = "https://api.ebay.com/oauth/api_scope"
        let bodyString = "grant_type=client_credentials&scope=\(scope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scope)"
        request.httpBody = bodyString.data(using: .utf8)
        
        // Exécuter la requête
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "EbayImageSearch",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Invalid OAuth response"]
            )
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "EbayImageSearch",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "OAuth token error (HTTP \(httpResponse.statusCode)): \(errorMessage)"]
            )
        }
        
        // Parser la réponse
        struct TokenResponse: Codable {
            let access_token: String
            let expires_in: Int?  // Durée de validité en secondes
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        
        // Calculer l'expiry (par défaut 2h, on garde 1h45 de marge)
        let expirySeconds = tokenResponse.expires_in ?? 7200
        let expiryDate = Date().addingTimeInterval(TimeInterval(expirySeconds - 900))  // -15 min de marge
        
        // Mettre en cache
        cachedToken = (token: tokenResponse.access_token, expiry: expiryDate)
        
        return tokenResponse.access_token
    }
    
    // MARK: - Models
    
    struct SearchResult: Identifiable {
        let id = UUID()
        let playerName: String
        let year: String
        let company: String
        let setName: String
        let cardNumber: String
        let confidence: Double
        let ebayTitle: String
        let ebayURL: String
        let price: String?
        let source: SearchSource
        
        enum SearchSource {
            case imageSearch
            case textFallback
            case hybrid
        }
    }
    
    struct EbayResponse: Codable {
        let itemSummaries: [ItemSummary]?
        let warnings: [Warning]?
        let errors: [ErrorDetail]?
        
        struct ItemSummary: Codable {
            let title: String
            let itemWebUrl: String?
            let price: Price?
            let image: Image?
            
            struct Price: Codable {
                let value: String
                let currency: String
            }
            
            struct Image: Codable {
                let imageUrl: String
            }
        }
        
        struct Warning: Codable {
            let message: String
        }
        
        struct ErrorDetail: Codable {
            let message: String
        }
    }
    
    // MARK: - Main Search Function (with fallback)
    
    /// 🔥 NOUVELLE FONCTION PRINCIPALE - Recherche intelligente avec fallback automatique
    static func searchCardWithFallback(
        image: UIImage,
        ocrYear: String? = nil,
        ocrCompany: String? = nil,
        ocrSet: String? = nil,
        ocrNumber: String? = nil,
        ocrPlayer: String? = nil
    ) async throws -> [SearchResult] {
        
        // 1️⃣ D'abord essayer Image Search
        do {
            let imageResults = try await searchCard(image: image)
            
            // Si on a au moins 1 résultat avec confiance > 50%, c'est bon
            if !imageResults.isEmpty, imageResults[0].confidence >= 0.5 {
                return Array(imageResults.prefix(3))  // Top 3
            }
            
            // Si confiance faible, essayer de combiner avec OCR
            if let ocrPlayer, !ocrPlayer.isEmpty,
               let ocrYear, !ocrYear.isEmpty {
                print("🔄 Image Search confiance faible, essai recherche hybride...")
                let hybridResults = try await searchByTextFallback(
                    player: ocrPlayer,
                    year: ocrYear,
                    company: ocrCompany,
                    set: ocrSet,
                    number: ocrNumber,
                    source: .hybrid
                )
                
                // ✅ TRACKING: Recherche Hybride (Image + Text)
                EbayUsageTracker.shared.trackHybridSearch(success: !hybridResults.isEmpty)
                
                // Fusionner les résultats (Image + Text)
                return mergeResults(imageResults: imageResults, textResults: hybridResults)
            }
            
            // Si pas d'OCR, retourner les résultats Image même faibles
            return Array(imageResults.prefix(3))
            
        } catch {
            print("❌ Image Search échoué: \(error.localizedDescription)")
            
            // ✅ TRACKING: Image Search a échoué
            EbayUsageTracker.shared.trackImageSearch(success: false)
            
            // 2️⃣ Fallback: Recherche texte eBay avec info OCR
            if let ocrPlayer, !ocrPlayer.isEmpty {
                print("🔄 Fallback vers recherche texte eBay...")
                let textResults = try await searchByTextFallback(
                    player: ocrPlayer,
                    year: ocrYear,
                    company: ocrCompany,
                    set: ocrSet,
                    number: ocrNumber,
                    source: .textFallback
                )
                
                // ✅ TRACKING: Text Fallback
                EbayUsageTracker.shared.trackTextSearch(success: !textResults.isEmpty)
                
                return textResults
            }
            
            throw error
        }
    }
    
    /// Recherche texte eBay (fallback quand Image Search échoue)
    private static func searchByTextFallback(
        player: String,
        year: String?,
        company: String?,
        set: String?,
        number: String?,
        source: SearchResult.SearchSource
    ) async throws -> [SearchResult] {
        
        // Construire la query
        var queryParts: [String] = []
        if let year, !year.isEmpty { queryParts.append(year) }
        if let company, !company.isEmpty { queryParts.append(company) }
        queryParts.append(player)
        if let set, !set.isEmpty { queryParts.append(set) }
        if let number, !number.isEmpty { queryParts.append(number) }
        
        let query = queryParts.joined(separator: " ")
        
        // Utiliser Finding API via le proxy existant (si configuré)
        // Sinon, utiliser Browse API text search
        let token = try await getAccessToken()
        
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let endpoint = "https://api.ebay.com/buy/browse/v1/item_summary/search?q=\(encodedQuery)&category_ids=213&limit=10"
        
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "EbayImageSearch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(marketplaceID, forHTTPHeaderField: "X-EBAY-C-MARKETPLACE-ID")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "EbayImageSearch", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "EbayImageSearch", code: httpResponse.statusCode,
                         userInfo: [NSLocalizedDescriptionKey: "eBay API error: \(errorMessage)"])
        }
        
        let ebayResponse = try JSONDecoder().decode(EbayResponse.self, from: data)
        
        guard let items = ebayResponse.itemSummaries, !items.isEmpty else {
            return []
        }
        
        return items.enumerated().compactMap { (index, item) in
            parseCardInfo(from: item.title, ebayURL: item.itemWebUrl ?? "",
                         price: item.price?.value, index: index, source: source)
        }
    }
    
    /// Fusionne les résultats Image et Text
    private static func mergeResults(imageResults: [SearchResult], textResults: [SearchResult]) -> [SearchResult] {
        var merged: [SearchResult] = []
        var seenTitles = Set<String>()
        
        // Ajouter d'abord les résultats image (priorité)
        for result in imageResults {
            let key = result.ebayTitle.lowercased()
            if !seenTitles.contains(key) {
                seenTitles.insert(key)
                merged.append(result)
            }
        }
        
        // Ajouter les résultats texte non-dupliqués
        for result in textResults {
            let key = result.ebayTitle.lowercased()
            if !seenTitles.contains(key) {
                seenTitles.insert(key)
                merged.append(result)
            }
        }
        
        // Trier par confiance décroissante
        merged.sort { $0.confidence > $1.confidence }
        
        return Array(merged.prefix(5))
    }
    
    // MARK: - Image Search API Call
    
    /// Recherche une carte par image sur eBay
    static func searchCard(image: UIImage) async throws -> [SearchResult] {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw NSError(domain: "EbayImageSearch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to JPEG"])
        }
        
        // Obtenir le token automatiquement
        let token = try await getAccessToken()
        
        // Endpoint
        let endpoint = "https://api.ebay.com/buy/browse/v1/item_summary/search_by_image"
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "EbayImageSearch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        // Request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(marketplaceID, forHTTPHeaderField: "X-EBAY-C-MARKETPLACE-ID")
        
        // CRITICAL: eBay Image Search API requires base64-encoded image in JSON body
        let base64Image = imageData.base64EncodedString()
        let requestBody: [String: Any] = [
            "image": base64Image
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        // Execute
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Validate
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "EbayImageSearch", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "EbayImageSearch", code: httpResponse.statusCode, 
                         userInfo: [NSLocalizedDescriptionKey: "eBay API error: \(errorMessage)"])
        }
        
        // Parse
        let decoder = JSONDecoder()
        let ebayResponse = try decoder.decode(EbayResponse.self, from: data)
        
        // Check for errors
        if let errors = ebayResponse.errors, !errors.isEmpty {
            let errorMessages = errors.map { $0.message }.joined(separator: ", ")
            throw NSError(domain: "EbayImageSearch", code: 4, 
                         userInfo: [NSLocalizedDescriptionKey: "eBay errors: \(errorMessages)"])
        }
        
        // Convert to SearchResults
        guard let items = ebayResponse.itemSummaries, !items.isEmpty else {
            // ✅ TRACKING: Image Search - aucun résultat
            EbayUsageTracker.shared.trackImageSearch(success: false)
            return []
        }
        
        let results = items.enumerated().compactMap { (index, item) in
            parseCardInfo(from: item.title, ebayURL: item.itemWebUrl ?? "", 
                         price: item.price?.value, index: index, source: .imageSearch)
        }
        
        // ✅ TRACKING: Image Search réussi
        EbayUsageTracker.shared.trackImageSearch(success: !results.isEmpty)
        
        return results
    }
    
    // MARK: - Parsing
    
    /// Parse card info from eBay title
    private static func parseCardInfo(from title: String, ebayURL: String, 
                                      price: String?, index: Int,
                                      source: SearchResult.SearchSource) -> SearchResult? {
        print("📋 Parsing title: \(title)")
        
        // Extract company FIRST - expanded list with SP brands
        let companies: [(search: String, display: String)] = [
            ("Upper Deck", "Upper Deck"),
            ("SP Authentic", "Upper Deck"),
            ("SP Game Used", "Upper Deck"),
            ("O-Pee-Chee", "Upper Deck"),
            ("OPC", "Upper Deck"),
            ("Panini", "Panini"),
            ("Topps", "Topps"),
            ("Leaf", "Leaf"),
            ("Fleer", "Fleer")
        ]
        var company = ""
        var detectedBrand = "" // Keep track of specific brand (SP Authentic, etc.)
        for comp in companies {
            if title.range(of: comp.search, options: .caseInsensitive) != nil {
                company = comp.display
                detectedBrand = comp.search
                break
            }
        }
        // Also check for standalone "SP" which indicates Upper Deck
        if company.isEmpty {
            let spPattern = #"\bSP\b"#
            if title.range(of: spPattern, options: .regularExpression) != nil {
                company = "Upper Deck"
                detectedBrand = "SP"
            }
        }
        
        // Extract year (format: YYYY-YY or YYYY)
        let yearPattern = #"\b(20\d{2}[-–]\d{2}|20\d{2})\b"#
        let year = extractPattern(from: title, pattern: yearPattern) ?? ""
        
        // 🔥 FIXED: Extract player name with NHL team filtering
        let playerName = extractPlayerName(from: title) ?? ""
        print("  ✅ Player name extracted: [\(playerName)]")
        
        // 🔥 FIXED: Extract card number - chercher le # suivi de chiffres (pas de lettres)
        // Pattern amélioré: #461 mais pas #RC ou similaire
        var cardNumber = ""
        let numberPattern = #"#(\d{1,4})\b"#
        if let extracted = extractPattern(from: title, pattern: numberPattern) {
            cardNumber = "#\(extracted)"
        }
        
        // Si pas trouvé avec #, chercher un nombre isolé de 3 chiffres (typique des Young Guns: 201-500)
        if cardNumber.isEmpty {
            let standaloneNumberPattern = #"\b([4-5]\d{2}|[2-3]\d{2})\b"#
            if let num = extractPattern(from: title, pattern: standaloneNumberPattern) {
                // Vérifier que ce n'est pas une année
                if let numInt = Int(num), numInt >= 100 && numInt <= 999 {
                    cardNumber = "#\(num)"
                }
            }
        }
        print("  ✅ Card number extracted: [\(cardNumber)]")
        
        // Extract set name - expanded list
        var setName = ""
        let knownSets = ["Young Guns", "Series 1", "Series 2", "Canvas", "Exclusives", "Update", "Extended",
                         "Future Watch", "SP Authentic", "Game Used", "Retro", "Autographs"]
        for set in knownSets {
            if let range = title.range(of: set, options: .caseInsensitive) {
                let afterSet = title[range.upperBound...]
                var foundSet = set
                
                for secondSet in knownSets where secondSet != set {
                    if let secondRange = afterSet.range(of: secondSet, options: .caseInsensitive) {
                        let between = afterSet[..<secondRange.lowerBound]
                        if between.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 {
                            foundSet = "\(set) \(secondSet)"
                            break
                        }
                    }
                }
                
                setName = foundSet
                break
            }
        }
        
        // 🔥 INFERENCE: If we have a card number but no set, try to infer from number ranges
        if setName.isEmpty, !cardNumber.isEmpty {
            let numStr = cardNumber.replacingOccurrences(of: "#", with: "")
            if let num = Int(numStr) {
                // SP Authentic typical ranges (varies by year)
                if detectedBrand.contains("SP") || title.lowercased().contains("sp") {
                    if (201...300).contains(num) {
                        setName = "Future Watch Autographs"
                    } else if (101...200).contains(num) {
                        setName = "Retro"
                    }
                }
                // Upper Deck Series 1/2 Young Guns
                else if company == "Upper Deck" || title.lowercased().contains("upper deck") {
                    if (201...250).contains(num) {
                        setName = "Series 1 Young Guns"
                    } else if (451...500).contains(num) {
                        setName = "Series 2 Young Guns"
                    }
                }
            }
        }
        
        if setName.isEmpty {
            if let companyRange = title.range(of: company, options: .caseInsensitive),
               let numberRange = title.range(of: "#") {
                if numberRange.lowerBound > companyRange.upperBound {
                    let setBetween = title[companyRange.upperBound..<numberRange.lowerBound]
                    setName = cleanSetName(setBetween, playerName: playerName, year: year)
                } else if companyRange.lowerBound > numberRange.upperBound {
                    let setBetween = title[numberRange.upperBound..<companyRange.lowerBound]
                    setName = cleanSetName(setBetween, playerName: playerName, year: year)
                }
            }
        }
        
        // Confidence: ajusté selon la source
        var confidence = max(0.3, 1.0 - (Double(index) * 0.1))
        if source == .textFallback {
            confidence *= 0.8
        } else if source == .hybrid {
            confidence *= 0.9
        }
        
        return SearchResult(
            playerName: playerName,
            year: year,
            company: company,
            setName: setName,
            cardNumber: cardNumber,
            confidence: confidence,
            ebayTitle: title,
            ebayURL: ebayURL,
            price: price,
            source: source
        )
    }
    
    /// Nettoie le set name
    private static func cleanSetName(_ rawSet: String.SubSequence, playerName: String, year: String) -> String {
        var cleaned = String(rawSet)
        
        if !playerName.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: playerName, with: "", options: .caseInsensitive)
        }
        
        if !year.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: year, with: "")
        }
        
        cleaned = cleaned.replacingOccurrences(of: " - ", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned
    }
    
    /// 🔥 FIXED: Extract player name from title, filtering out NHL teams and bad words
    private static func extractPlayerName(from title: String) -> String? {
        // Pattern: deux mots consécutifs capitalisés (First Last)
        let pattern = #"\b([A-Z][a-z']+)\s+([A-Z][a-z']+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        
        let range = NSRange(title.startIndex..., in: title)
        let matches = regex.matches(in: title, options: [], range: range)
        
        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            
            // Extraire les deux mots séparément
            guard let range1 = Range(match.range(at: 1), in: title),
                  let range2 = Range(match.range(at: 2), in: title) else { continue }
            
            let word1 = String(title[range1]).lowercased()
            let word2 = String(title[range2]).lowercased()
            
            // 🔥 CRITICAL: Vérifier que AUCUN des deux mots n'est une équipe NHL ou un mot interdit
            if nhlTeamsAndBadWords.contains(word1) { continue }
            if nhlTeamsAndBadWords.contains(word2) { continue }
            
            // 🎨 Couleurs comme Green/White/Red: OK en nom de famille, PAS en prénom
            // "Blue Frank" → rejeté, "Colin White" → accepté
            if colorsOnlyBadAsFirstName.contains(word1) { continue }
            
            // Si les deux mots passent le filtre, c'est probablement un nom de joueur
            let firstName = String(title[range1])
            let lastName = String(title[range2])
            
            // Vérification supplémentaire: les noms doivent avoir au moins 2 caractères
            if firstName.count >= 2 && lastName.count >= 2 {
                return "\(firstName) \(lastName)"
            }
        }
        
        return nil
    }
    
    /// Extract pattern from string using regex
    private static func extractPattern(from text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        
        if match.numberOfRanges > 1 {
            let groupRange = match.range(at: 1)
            if groupRange.location != NSNotFound,
               let swiftRange = Range(groupRange, in: text) {
                return String(text[swiftRange])
            }
        }
        
        if let swiftRange = Range(match.range, in: text) {
            return String(text[swiftRange])
        }
        
        return nil
    }
}

// MARK: - Extensions for Integration

extension EbayImageSearch {
    
    /// 🔥 NOUVELLE INTÉGRATION - Recherche avec choix multiple et fallback automatique
    static func searchAndPopulateFieldsWithOptions(
        image: UIImage,
        currentYear: String,
        currentCompany: String,
        currentSet: String,
        currentNumber: String,
        currentPlayer: String
    ) async throws -> (
        topResults: [SearchResult],
        debugInfo: String
    ) {
        let results = try await searchCardWithFallback(
            image: image,
            ocrYear: currentYear.isEmpty ? nil : currentYear,
            ocrCompany: currentCompany.isEmpty ? nil : currentCompany,
            ocrSet: currentSet.isEmpty ? nil : currentSet,
            ocrNumber: currentNumber.isEmpty ? nil : currentNumber,
            ocrPlayer: currentPlayer.isEmpty ? nil : currentPlayer
        )
        
        guard !results.isEmpty else {
            throw NSError(domain: "EbayImageSearch", code: 5, 
                         userInfo: [NSLocalizedDescriptionKey: "Aucun résultat trouvé"])
        }
        
        // Debug info amélioré
        let debugInfo = """
        eBay Search Results:
        
        Source: \(results[0].source == .imageSearch ? "Image Search" : results[0].source == .textFallback ? "Text Fallback" : "Hybrid")
        
        Top 3 Options:
        \(results.prefix(3).enumerated().map { (i, r) in
            """
            \(i+1). \(r.playerName.isEmpty ? "?" : r.playerName) - \(r.year) \(r.company) \(r.setName) \(r.cardNumber)
               Confiance: \(Int(r.confidence * 100))%
               Titre: \(r.ebayTitle)
            """
        }.joined(separator: "\n\n"))
        
        Total: \(results.count) résultats
        """
        
        return (
            topResults: Array(results.prefix(3)),
            debugInfo: debugInfo
        )
    }
    
    /// Legacy function (pour compatibilité)
    static func searchAndPopulateFields(
        image: UIImage,
        currentYear: String,
        currentCompany: String,
        currentSet: String,
        currentNumber: String,
        currentPlayer: String
    ) async throws -> (
        playerName: String,
        year: String,
        company: String,
        setName: String,
        cardNumber: String,
        confidence: Double,
        debugInfo: String
    ) {
        let (topResults, rawDebugInfo) = try await searchAndPopulateFieldsWithOptions(
            image: image,
            currentYear: currentYear,
            currentCompany: currentCompany,
            currentSet: currentSet,
            currentNumber: currentNumber,
            currentPlayer: currentPlayer
        )
        
        // 🔥 VALIDATION CROISÉE OCR/eBay
        // Si l'OCR a détecté un nom, chercher ce nom dans les résultats eBay
        let best = selectBestResult(
            from: topResults,
            ocrPlayer: currentPlayer,
            ocrNumber: currentNumber,
            ocrSet: currentSet  // 🔥 Passer le set pour validation de plage YG
        )
        
        // Debug info enrichi
        let debugInfo = """
        \(rawDebugInfo)
        
        🔍 Validation OCR:
        - OCR Player: \(currentPlayer.isEmpty ? "(vide)" : currentPlayer)
        - OCR Number: \(currentNumber.isEmpty ? "(vide)" : currentNumber)
        - OCR Set: \(currentSet.isEmpty ? "(vide)" : currentSet)
        - Résultat sélectionné: \(best.playerName) \(best.cardNumber)
        """
        
        return (
            playerName: best.playerName.isEmpty ? currentPlayer : best.playerName,
            year: best.year.isEmpty ? currentYear : best.year,
            company: best.company.isEmpty ? currentCompany : best.company,
            setName: best.setName.isEmpty ? currentSet : best.setName,
            cardNumber: best.cardNumber.isEmpty ? currentNumber : best.cardNumber,
            confidence: best.confidence,
            debugInfo: debugInfo
        )
    }
    
    // MARK: - OCR/eBay Cross-Validation
    
    /// Sélectionne le meilleur résultat en croisant avec les données OCR
    /// 🔥 FIX: Quand le nom matche, faire confiance au numéro eBay (pas OCR)
    ///         + Validation de plage pour Young Guns
    private static func selectBestResult(
        from results: [SearchResult],
        ocrPlayer: String,
        ocrNumber: String,
        ocrSet: String = ""
    ) -> SearchResult {
        guard !results.isEmpty else {
            fatalError("selectBestResult appelé avec tableau vide")
        }
        
        // Si pas d'OCR player, retourner le premier résultat
        let hasOcrPlayer = !ocrPlayer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        if !hasOcrPlayer {
            return results[0]
        }
        
        // Normaliser pour comparaison
        let ocrPlayerNorm = normalizeForComparison(ocrPlayer)
        let ocrSetUpper = ocrSet.uppercased()
        
        // Détecter si c'est une Young Guns (Series 1: #201-250, Series 2: #451-500)
        let isYoungGuns = ocrSetUpper.contains("YOUNG") && ocrSetUpper.contains("GUN")
        let isYGSeries2 = isYoungGuns && (ocrSetUpper.contains("SERIES 2") || ocrSetUpper.contains("S2") || ocrSetUpper.contains("SER 2"))
        let isYGSeries1 = isYoungGuns && (ocrSetUpper.contains("SERIES 1") || ocrSetUpper.contains("S1") || ocrSetUpper.contains("SER 1"))
        
        print("🔍 Validation OCR - Player: \(ocrPlayer), Set: \(ocrSet)")
        print("   YG detected: \(isYoungGuns), S1: \(isYGSeries1), S2: \(isYGSeries2)")
        
        // Scorer chaque résultat
        var scoredResults: [(result: SearchResult, score: Int, nameMatched: Bool)] = []
        
        for result in results {
            var score = 0
            var nameMatched = false
            
            // Match sur le nom du joueur
            if !result.playerName.isEmpty {
                let ebayPlayerNorm = normalizeForComparison(result.playerName)
                
                // Match exact (+150 points - très important!)
                if ocrPlayerNorm == ebayPlayerNorm {
                    score += 150
                    nameMatched = true
                }
                // Match partiel (nom de famille)
                else if ocrPlayerNorm.split(separator: " ").last == ebayPlayerNorm.split(separator: " ").last {
                    score += 100
                    nameMatched = true
                }
                // Match dans le titre eBay
                else if result.ebayTitle.lowercased().contains(ocrPlayerNorm) {
                    score += 70
                    nameMatched = true
                }
            }
            
            // 🔥 VALIDATION DE PLAGE YOUNG GUNS
            // Quand le nom matche et qu'on a un set Young Guns, valider le numéro eBay
            // au lieu de matcher le numéro OCR (souvent faux = numéro de maillot)
            if nameMatched && !result.cardNumber.isEmpty {
                let ebayNumberNorm = normalizeCardNumber(result.cardNumber)
                if let cardNum = Int(ebayNumberNorm) {
                    
                    if isYGSeries2 {
                        // Young Guns Series 2: numéros 451-500
                        if (451...500).contains(cardNum) {
                            score += 100  // Gros bonus: numéro dans la bonne plage!
                            print("  ✅ \(result.playerName) #\(cardNum) dans plage YG S2 (451-500)")
                        } else {
                            score -= 50  // Pénalité: hors plage
                            print("  ❌ \(result.playerName) #\(cardNum) HORS plage YG S2")
                        }
                    }
                    else if isYGSeries1 {
                        // Young Guns Series 1: numéros 201-250
                        if (201...250).contains(cardNum) {
                            score += 100
                            print("  ✅ \(result.playerName) #\(cardNum) dans plage YG S1 (201-250)")
                        } else {
                            score -= 50
                            print("  ❌ \(result.playerName) #\(cardNum) HORS plage YG S1")
                        }
                    }
                    else if isYoungGuns {
                        // Young Guns générique: accepter les deux plages
                        if (201...250).contains(cardNum) || (451...500).contains(cardNum) {
                            score += 80
                            print("  ✅ \(result.playerName) #\(cardNum) dans plage YG")
                        }
                    }
                    else {
                        // Pas Young Guns: bonus léger si numéro a du sens (1-999)
                        if cardNum >= 1 && cardNum <= 999 {
                            score += 20
                        }
                    }
                }
            }
            
            // Bonus de position (premier résultat eBay = probablement plus pertinent)
            let positionBonus = max(0, 30 - (scoredResults.count * 10))
            score += positionBonus
            
            scoredResults.append((result, score, nameMatched))
        }
        
        // Trier par score décroissant
        scoredResults.sort { $0.score > $1.score }
        
        print("🎯 Scores de validation OCR/eBay:")
        for (i, scored) in scoredResults.prefix(3).enumerated() {
            print("  \(i+1). \(scored.result.playerName) \(scored.result.cardNumber) → Score: \(scored.score) (name: \(scored.nameMatched))")
        }
        
        return scoredResults[0].result
    }
    
    /// Normalise un nom pour comparaison (lowercase, sans accents)
    private static func normalizeForComparison(_ text: String) -> String {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Normalise un numéro de carte (garde juste les chiffres)
    private static func normalizeCardNumber(_ number: String) -> String {
        let digits = number.filter { $0.isNumber }
        return digits
    }
}
