
import Foundation

// ✅ eBay price estimator (V1): uses ACTIVE listings (Browse API)
// Tries US first, then CA. Robust filtering + retry on 5xx.
enum EbayPriceEstimator {

    struct Estimate: Sendable {
        let min: Double
        let median: Double
        let max: Double
        let sampleCount: Int
        let confidence: Double?
        let currency: String
    }

    enum EstimatorError: LocalizedError {
        case missingCredentials
        case http(Int, String?)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "Configuration eBay manquante (Client ID / Secret)."
            case .http(let code, let msg):
                return msg.map { "Erreur eBay (\(code)) : \($0)" } ?? "Erreur eBay (\(code))."
            case .decode(let msg):
                return "Décodage eBay impossible: \(msg)"
            }
        }
    }

    // MARK: - Marketplaces
    private enum Marketplace: String {
        case us = "EBAY_US"
        case ca = "EBAY_CA"
    }

    // MARK: - Public API
    static func estimateActiveListingPrice(
        year: String?,
        company: String?,
        setName: String?,
        cardNumber: String?,
        playerName: String?,
        isGraded: Bool? = nil,
        gradingCompany: String? = nil,
        gradeValue: String? = nil
    ) async throws -> Estimate? {

        guard let clientId = InfoPlist.ebayClientId,
              let clientSecret = InfoPlist.ebayClientSecret,
              !clientId.isEmpty, !clientSecret.isEmpty else {
            throw EstimatorError.missingCredentials
        }

        let token = try await EbayAuth.appAccessToken(
            clientId: clientId,
            clientSecret: clientSecret
        )

        let query = buildQuery(
            year: year,
            company: company,
            setName: setName,
            cardNumber: cardNumber,
            playerName: playerName,
            isGraded: isGraded,
            gradingCompany: gradingCompany,
            gradeValue: gradeValue
        )
        
        // 🔍 LOG: Afficher la requête générée
        print("🔍 eBay Query: \"\(query)\"")

        for marketplace in [Marketplace.us, Marketplace.ca] {
            let decoded = try await fetchBrowseSearch(
                query: query,
                token: token,
                marketplace: marketplace
            )
            if let estimate = estimateFromDecoded(decoded, isGraded: isGraded) {
                return estimate
            }
        }

        return nil
    }

    // MARK: - Browse
    private static func fetchBrowseSearch(
        query: String,
        token: String,
        marketplace: Marketplace
    ) async throws -> BrowseSearchResponse {

        var comps = URLComponents(string: "https://api.ebay.com/buy/browse/v1/item_summary/search")!
        comps.queryItems = [
            .init(name: "q", value: query),
            .init(name: "limit", value: "200")  // ✅ Augmenté de 50 à 200
        ]

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(marketplace.rawValue, forHTTPHeaderField: "X-EBAY-C-MARKETPLACE-ID")

        for attempt in 0..<3 {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as! HTTPURLResponse

            if (500...599).contains(http.statusCode), attempt < 2 {
                try await Task.sleep(nanoseconds: attempt == 0 ? 250_000_000 : 750_000_000)
                continue
            }

            guard (200...299).contains(http.statusCode) else {
                throw EstimatorError.http(http.statusCode, String(data: data, encoding: .utf8))
            }

            return try JSONDecoder().decode(BrowseSearchResponse.self, from: data)
        }

        throw EstimatorError.http(-1, "Échec réseau eBay")
    }

    private static func estimateFromDecoded(
        _ decoded: BrowseSearchResponse,
        isGraded: Bool?
    ) -> Estimate? {

        let items = decoded.itemSummaries ?? []
        let currency = items.first?.price?.currency ?? "CAD"
        
        // 🔍 LOG: Nombre total de résultats eBay
        print("📊 Total eBay results: \(items.count)")

        // Filtrer et collecter les titres acceptés pour debug
        var acceptedTitles: [(String, Double)] = []
        let prices = items
            .compactMap { item -> (String, Double)? in
                guard let title = item.title,
                      isRelevantTitle(title, isGraded: isGraded),
                      let price = item.price?.valueDouble,
                      price > 0 else {
                    return nil
                }
                return (title, price)
            }
            .sorted { $0.1 < $1.1 }
        
        // 🔍 LOG: Résultats après filtrage + échantillon de titres
        print("✅ After filtering: \(prices.count) prices")
        if !prices.isEmpty {
            print("   Range: \(prices.first!.1) - \(prices.last!.1)")
            print("   Sample titles (first 3):")
            for (title, price) in prices.prefix(3) {
                print("      • [\(price)] \(title)")
            }
        }
        
        let priceValues = prices.map { $0.1 }

        guard priceValues.count >= 3 else {  // ✅ Réduit de 5 à 3 pour cartes moins populaires
            print("⚠️ Not enough results (\(priceValues.count) < 3)")
            return nil 
        }
        
        // 🔍 Détecter et filtrer les outliers extrêmes AVANT le trimming
        let initialMedian = median(priceValues)
        let maxReasonablePrice = initialMedian * 1.6  // ✅ Réduit de 2.5x à 1.6x (plus agressif)
        
        let filteredPrices = priceValues.filter { $0 <= maxReasonablePrice }
        
        print("🔍 Outlier filtering:")
        print("   Initial median: \(initialMedian)")
        print("   Max reasonable: \(maxReasonablePrice)")
        print("   Filtered out: \(priceValues.count - filteredPrices.count) prices")
        
        guard filteredPrices.count >= 3 else {  // ✅ Réduit de 5 à 3
            print("⚠️ Not enough after outlier filter (\(filteredPrices.count) < 3)")
            return nil
        }

        // ✅ Adapter le trimming selon le nombre de résultats
        let (lowPercent, highPercent): (Double, Double)
        if filteredPrices.count < 8 {
            // Peu de résultats → trimming léger pour garder assez de données
            (lowPercent, highPercent) = (0.05, 0.20)
            print("📊 Small sample → light trimming (5% low, 20% high)")
        } else {
            // Beaucoup de résultats → trimming agressif pour éliminer outliers
            (lowPercent, highPercent) = (0.10, 0.40)
            print("📊 Large sample → aggressive trimming (10% low, 40% high)")
        }
        
        let trimmed = trim(filteredPrices, lowerPercent: lowPercent, upperPercent: highPercent)
        
        // 🔍 LOG: Après trimming
        print("📈 After trimming: \(trimmed.count) prices")
        if !trimmed.isEmpty {
            print("   Range: \(trimmed.first!) - \(trimmed.last!)")
        }
        
        guard trimmed.count >= 3 else {  // ✅ Réduit de 5 à 3
            print("⚠️ Not enough after trim (\(trimmed.count) < 3)")
            return nil 
        }

        let minV = trimmed.first!
        let maxV = trimmed.last!
        let medianV = median(trimmed)
        
        // 🔍 LOG: Résultat final
        print("💰 Final estimate: min=\(minV), median=\(medianV), max=\(maxV)")

        let spread = (maxV - minV) / max(1, medianV)
        let confidence = min(1.0, 0.3 + Double(trimmed.count) / 50.0 - spread)

        return Estimate(
            min: minV,
            median: medianV,
            max: maxV,
            sampleCount: trimmed.count,
            confidence: confidence,
            currency: currency
        )
    }

    // MARK: - Filtering
    private static func isRelevantTitle(_ raw: String, isGraded: Bool?) -> Bool {
        let t = raw.lowercased()

        let banned = [
            "lot", "break", "box", "pack", "binder", "sleeve",
            "reprint", "fake", "digital", "nft",
            "auto", "autograph", "signed", "signature",  // ✅ Autographes
            "jersey", "patch", "memorabilia", "relic",   // ✅ Memorabilia
            "prizm", "mosaic", "select",                 // ✅ Autres marques
            "/", "+", "&"                                 // ✅ Lots multiples
        ]
        if banned.contains(where: { t.contains($0) }) { 
            return false 
        }

        let gradingKeywords = ["psa", "bgs", "sgc", "cgc", "slab"]
        let hasGradingKeyword = gradingKeywords.contains(where: { t.contains($0) })
        
        // Si on cherche des cartes gradées, accepter SEULEMENT celles avec mot-clé de grading
        if isGraded == true {
            return hasGradingKeyword
        }
        
        // Si on cherche des cartes NON gradées, exclure celles avec mot-clé de grading
        if isGraded == false {
            return !hasGradingKeyword
        }
        
        // Si isGraded == nil, accepter tout
        return true
    }

    // MARK: - Stats
    private static func trim(_ sorted: [Double], lowerPercent: Double, upperPercent: Double) -> [Double] {
        let n = sorted.count
        let lo = Int(Double(n) * lowerPercent)
        let hi = Int(Double(n) * upperPercent)
        return Array(sorted[lo..<max(lo+1, n-hi)])
    }

    private static func median(_ sorted: [Double]) -> Double {
        let n = sorted.count
        return n % 2 == 1
            ? sorted[n/2]
            : (sorted[n/2-1] + sorted[n/2]) / 2
    }

    // MARK: - Query
    private static func buildQuery(
        year: String?,
        company: String?,
        setName: String?,
        cardNumber: String?,
        playerName: String?,
        isGraded: Bool?,
        gradingCompany: String?,
        gradeValue: String?
    ) -> String {

        var parts: [String] = []
        [playerName, year, company, setName].forEach {
            if let v = $0, !v.isEmpty { parts.append(v) }
        }

        if let num = cardNumber?.replacingOccurrences(of: "#", with: ""), !num.isEmpty {
            parts.append("#\(num)")
        }
        
        // ✅ Ajouter les infos de grading si la carte est gradée
        if isGraded == true {
            if let gradingComp = gradingCompany, !gradingComp.isEmpty {
                parts.append(gradingComp) // "PSA", "BGS", "SGC", "CGC"
            }
            
            if let grade = gradeValue, !grade.isEmpty {
                // Extraire le chiffre du grade (ex: "GEM MT 10" -> "10", "9.5" -> "9.5")
                let numericGrade = grade
                    .replacingOccurrences(of: "GEM MT", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "MINT", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !numericGrade.isEmpty {
                    parts.append(numericGrade)
                }
            }
        }

        return parts.joined(separator: " ")
    }
}

// MARK: - Auth
private enum EbayAuth {
    static func appAccessToken(clientId: String, clientSecret: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.ebay.com/identity/v1/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let basic = "\(clientId):\(clientSecret)".data(using: .utf8)!.base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

        req.httpBody = "grant_type=client_credentials&scope=https://api.ebay.com/oauth/api_scope".data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(TokenResponse.self, from: data).access_token
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
    }
}

// MARK: - Models
private struct BrowseSearchResponse: Decodable {
    let itemSummaries: [BrowseItemSummary]?
}

private struct BrowseItemSummary: Decodable {
    let title: String?
    let price: BrowsePrice?
}

private struct BrowsePrice: Decodable {
    let value: String?
    let currency: String?
    var valueDouble: Double? { value.flatMap(Double.init) }
}

// MARK: - Info.plist
private enum InfoPlist {
    static var ebayClientId: String? {
        Bundle.main.object(forInfoDictionaryKey: "EBAY_CLIENT_ID") as? String
    }
    static var ebayClientSecret: String? {
        Bundle.main.object(forInfoDictionaryKey: "EBAY_CLIENT_SECRET") as? String
    }
}
