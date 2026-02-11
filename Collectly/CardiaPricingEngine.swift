//
//  CardiaPricingEngine.swift
//  Cardia (Collectly)
//
//  Hybrid OCR + eBay pricing (CAD-first, items-only)
//  - Searches EBAY_CA + EBAY_US (Browse API) and converts to CAD
//  - Designed for “item only” (no shipping/taxes) price display
//  - Dynamic marketplace selection based on result quality
//
//  Notes:
//  - eBay “sold” results are not reliably available via modern public REST APIs.
//    The legacy Finding API’s findCompletedItems has been reported as deprecated/restricted.
//    This module therefore uses Browse API “active listings” as a fallback for price estimation.
//    (You can later swap in a SoldProvider if you get access to an official sold-data product.)
//
//  References:
//  - eBay Browse API Overview (X-EBAY-C-MARKETPLACE-ID header) and search method docs.
//  - eBay OAuth client-credentials grant flow docs.
//  - Bank of Canada Valet API (daily FX rates; cache to limit requests).
//

import Foundation

// MARK: - Core types

public enum CardiaCurrency: String, Codable, Sendable {
    case cad = "CAD"
    case usd = "USD"
}

public struct Money: Codable, Hashable, Sendable {
    public var amount: Decimal
    public var currency: CardiaCurrency

    public init(amount: Decimal, currency: CardiaCurrency) {
        self.amount = amount
        self.currency = currency
    }
}

public struct PriceSample: Codable, Hashable, Sendable {
    public var price: Money
    public var marketplace: EbayMarketplace
    public var itemId: String?
    public var title: String?
    public var url: String?
    public var fetchedAt: Date

    public init(price: Money, marketplace: EbayMarketplace, itemId: String? = nil, title: String? = nil, url: String? = nil, fetchedAt: Date = Date()) {
        self.price = price
        self.marketplace = marketplace
        self.itemId = itemId
        self.title = title
        self.url = url
        self.fetchedAt = fetchedAt
    }
}

public struct PriceEstimate: Codable, Hashable, Sendable {
    public var estimateCAD: Money
    public var n: Int
    public var method: String
    public var confidence: Double        // 0..1
    public var samples: [PriceSample]    // optional details for debug/UI

    public init(estimateCAD: Money, n: Int, method: String, confidence: Double, samples: [PriceSample]) {
        self.estimateCAD = estimateCAD
        self.n = n
        self.method = method
        self.confidence = confidence
        self.samples = samples
    }
}

// MARK: - Marketplace selection

public enum EbayMarketplace: String, Codable, CaseIterable, Sendable {
    case ebayUS = "EBAY_US"
    case ebayCA = "EBAY_CA"

    public var currency: CardiaCurrency {
        switch self {
        case .ebayUS: return .usd
        case .ebayCA: return .cad
        }
    }
}

public enum MarketplaceSelectionStrategy: String, Codable, Sendable {
    /// Always search CA then US, merge.
    case mergeBoth

    /// Search CA first; only add US if CA results are weak.
    case preferCAThenUS

    /// Search US first; only add CA if US results are weak.
    case preferUSThenCA

    /// Dynamically pick the best single marketplace based on results (then optionally add the other).
    case dynamic
}

public struct PricingConfig: Codable, Sendable {
    public var selectionStrategy: MarketplaceSelectionStrategy

    /// OCR confidence threshold under which we auto-trigger eBay (you gave 0.70).
    public var minOCRConfidenceToSkipEbay: Double

    /// How many listings to request per marketplace (max is limited by eBay & query).
    public var maxListingsPerMarketplace: Int

    /// Use only “item price” (no shipping/taxes). True per your spec.
    public var itemOnly: Bool

    /// Maximum acceptable price in CAD for filtering obvious junk (0 disables).
    public var hardMaxCAD: Decimal

    /// Drop bottom/top quantile to reduce outliers (e.g., 0.1 removes 10% low + 10% high).
    public var trimQuantile: Double

    /// How fresh FX rate must be; if stale, refresh.
    public var fxMaxAgeSeconds: TimeInterval

    public init(
        selectionStrategy: MarketplaceSelectionStrategy = .dynamic,
        minOCRConfidenceToSkipEbay: Double = 0.70,
        maxListingsPerMarketplace: Int = 50,
        itemOnly: Bool = true,
        hardMaxCAD: Decimal = 5000,
        trimQuantile: Double = 0.12,
        fxMaxAgeSeconds: TimeInterval = 60 * 60 * 12 // 12h
    ) {
        self.selectionStrategy = selectionStrategy
        self.minOCRConfidenceToSkipEbay = minOCRConfidenceToSkipEbay
        self.maxListingsPerMarketplace = maxListingsPerMarketplace
        self.itemOnly = itemOnly
        self.hardMaxCAD = hardMaxCAD
        self.trimQuantile = trimQuantile
        self.fxMaxAgeSeconds = fxMaxAgeSeconds
    }
}

// MARK: - FX (USD -> CAD)

public protocol FXRateProviding: Sendable {
    /// Returns CAD per 1 USD (USD→CAD).
    func usdToCadRate() async throws -> Decimal
}

public actor FixedFXRateProvider: FXRateProviding {
    private let rate: Decimal
    public init(rate: Decimal) { self.rate = rate }
    public func usdToCadRate() async throws -> Decimal { rate }
}

public actor BankOfCanadaValetFXProvider: FXRateProviding {
    private var cachedRate: Decimal?
    private var cachedAt: Date?

    private let session: URLSession
    private let maxAge: TimeInterval

    /// Uses Valet “observations” endpoint for USD/CAD.
    /// We try series FXUSDCAD first (USD→CAD), then FXCADUSD (CAD→USD) and invert.
    public init(session: URLSession = .shared, maxAgeSeconds: TimeInterval = 60 * 60 * 12) {
        self.session = session
        self.maxAge = maxAgeSeconds
    }

    public func usdToCadRate() async throws -> Decimal {
        if let cachedRate, let cachedAt, Date().timeIntervalSince(cachedAt) <= maxAge {
            return cachedRate
        }

        // Try USD->CAD directly
        if let direct = try await fetchLatestSeriesDecimal(series: "FXUSDCAD") {
            cachedRate = direct
            cachedAt = Date()
            return direct
        }

        // Try CAD->USD then invert
        if let cadUsd = try await fetchLatestSeriesDecimal(series: "FXCADUSD") {
            if cadUsd == 0 { throw NSError(domain: "FX", code: 2, userInfo: [NSLocalizedDescriptionKey: "FXCADUSD was 0"]) }
            let inverted = (Decimal(1) / cadUsd)
            cachedRate = inverted
            cachedAt = Date()
            return inverted
        }

        throw NSError(domain: "FX", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to fetch USD/CAD rate from Bank of Canada Valet API."])
    }

    private func fetchLatestSeriesDecimal(series: String) async throws -> Decimal? {
        // recent=1 gets latest available observation
        guard let url = URL(string: "https://www.bankofcanada.ca/valet/observations/\(series)/json?recent=1") else { return nil }
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }

        struct ValetResponse: Decodable {
            struct Observation: Decodable {
                struct V: Decodable { let v: String? }
                let d: String?
                let FXUSDCAD: V?
                let FXCADUSD: V?
            }
            let observations: [Observation]?
        }

        let decoded = try JSONDecoder().decode(ValetResponse.self, from: data)
        guard let obs = decoded.observations?.first else { return nil }

        let vStr: String?
        if series == "FXUSDCAD" {
            vStr = obs.FXUSDCAD?.v
        } else {
            vStr = obs.FXCADUSD?.v
        }
        guard let s = vStr, let d = Decimal(string: s) else { return nil }
        return d
    }
}

// MARK: - eBay OAuth (client credentials)

public actor EbayOAuthTokenProvider {
    public struct Config: Sendable {
        public var clientId: String
        public var clientSecret: String
        public var sandbox: Bool

        public init(clientId: String, clientSecret: String, sandbox: Bool = false) {
            self.clientId = clientId
            self.clientSecret = clientSecret
            self.sandbox = sandbox
        }
    }

    private let config: Config
    private let session: URLSession

    private var cachedToken: String?
    private var expiresAt: Date?

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func token() async throws -> String {
        if let cachedToken, let expiresAt, Date() < expiresAt.addingTimeInterval(-60) {
            return cachedToken
        }

        let base = config.sandbox ? "https://api.sandbox.ebay.com" : "https://api.ebay.com"
        guard let url = URL(string: "\(base)/identity/v1/oauth2/token") else {
            throw NSError(domain: "eBayOAuth", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid token URL"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let basic = "\(config.clientId):\(config.clientSecret)"
        let basicData = basic.data(using: .utf8) ?? Data()
        let basicB64 = basicData.base64EncodedString()
        req.setValue("Basic \(basicB64)", forHTTPHeaderField: "Authorization")

        // Public app-level access
        let scope = "https://api.ebay.com/oauth/api_scope"
        let body = "grant_type=client_credentials&scope=\(urlEncode(scope))"
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "eBayOAuth", code: 0, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "eBayOAuth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Token error \(http.statusCode): \(msg)"])
        }

        struct TokenResp: Decodable {
            let access_token: String
            let expires_in: Int
            let token_type: String?
        }

        let decoded = try JSONDecoder().decode(TokenResp.self, from: data)
        cachedToken = decoded.access_token
        expiresAt = Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        return decoded.access_token
    }

    private func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}

// MARK: - eBay Browse Search (active listings)

public actor EbayBrowseClient {
    public struct Config: Sendable {
        public var sandbox: Bool
        public init(sandbox: Bool = false) { self.sandbox = sandbox }
    }

    private let config: Config
    private let tokenProvider: EbayOAuthTokenProvider
    private let session: URLSession

    public init(config: Config, tokenProvider: EbayOAuthTokenProvider, session: URLSession = .shared) {
        self.config = config
        self.tokenProvider = tokenProvider
        self.session = session
    }

    public func searchActiveListings(
        keywords: String,
        marketplace: EbayMarketplace,
        limit: Int,
        categoryIds: [String] = [],
        aspectFilter: String? = nil
    ) async throws -> [PriceSample] {
        let base = config.sandbox ? "https://api.sandbox.ebay.com" : "https://api.ebay.com"
        var comps: [URLQueryItem] = [
            URLQueryItem(name: "q", value: keywords),
            URLQueryItem(name: "limit", value: String(max(1, min(200, limit))))
        ]
        if !categoryIds.isEmpty {
            comps.append(URLQueryItem(name: "category_ids", value: categoryIds.joined(separator: ",")))
        }
        if let aspectFilter, !aspectFilter.isEmpty {
            comps.append(URLQueryItem(name: "aspect_filter", value: aspectFilter))
        }

        var urlComps = URLComponents(string: "\(base)/buy/browse/v1/item_summary/search")
        urlComps?.queryItems = comps

        guard let url = urlComps?.url else {
            throw NSError(domain: "eBayBrowse", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid search URL"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(try await tokenProvider.token())", forHTTPHeaderField: "Authorization")
        req.setValue(marketplace.rawValue, forHTTPHeaderField: "X-EBAY-C-MARKETPLACE-ID")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "eBayBrowse", code: 0, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "eBayBrowse", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Search error \(http.statusCode): \(msg)"])
        }

        struct BrowseResp: Decodable {
            struct ItemSummary: Decodable {
                struct Price: Decodable { let value: String?; let currency: String? }
                let itemId: String?
                let title: String?
                let itemWebUrl: String?
                let price: Price?
            }
            let itemSummaries: [ItemSummary]?
        }

        let decoded = try JSONDecoder().decode(BrowseResp.self, from: data)
        let items = decoded.itemSummaries ?? []

        var out: [PriceSample] = []
        out.reserveCapacity(items.count)

        for it in items {
            guard let p = it.price, let v = p.value, let dec = Decimal(string: v) else { continue }
            let cur = await MainActor.run { marketplace.currency }
            let sample = PriceSample(
                price: await MainActor.run { Money(amount: dec, currency: cur) },
                marketplace: marketplace,
                itemId: it.itemId,
                title: it.title,
                url: it.itemWebUrl,
                fetchedAt: Date()
            )
            out.append(sample)
        }
        return out
    }
}

// MARK: - Price Estimator

public actor CardiaPriceEstimator {

    private let config: PricingConfig
    private let ebay: EbayBrowseClient
    private let fx: FXRateProviding

    public init(config: PricingConfig, ebay: EbayBrowseClient, fx: FXRateProviding) {
        self.config = config
        self.ebay = ebay
        self.fx = fx
    }

    /// Main entry point.
    /// - Parameters:
    ///   - keywords: The query we send to eBay (ex: "2024-25 Upper Deck Series 1 Encore Matthew Knies C-69")
    ///   - ocrConfidence: If < threshold, we auto-trigger eBay (you asked).
    /// - Returns: Price estimate in CAD (item-only).
    public func estimatePriceCAD(
        keywords: String,
        ocrConfidence: Double
    ) async throws -> PriceEstimate {
        let shouldUseEbay = (ocrConfidence < config.minOCRConfidenceToSkipEbay)

        guard shouldUseEbay else {
            // If OCR confidence is high, we “skip” eBay.
            // Return a placeholder with OCR-based confidence to let UI decide to show “—”.
            return PriceEstimate(
                estimateCAD: await MainActor.run { Money(amount: 0, currency: .cad) },
                n: 0,
                method: "ocr-only",
                confidence: min(1, max(0, ocrConfidence)),
                samples: []
            )
        }

        let samples = try await fetchSamplesDynamic(keywords: keywords)
        let filtered = try await filterAndConvertToCAD(samples)

        let trimmed = trimOutliers(filtered, quantile: config.trimQuantile)
        let estimate = median(trimmed.map { $0.price.amount })

        let confidence = confidenceScore(n: trimmed.count, spread: iqr(trimmed.map { $0.price.amount }))
        return PriceEstimate(
            estimateCAD: await MainActor.run { Money(amount: estimate, currency: .cad) },
            n: trimmed.count,
            method: "ebay-browse-active",
            confidence: confidence,
            samples: trimmed
        )
    }

    // MARK: Selection / Fetch

    private func fetchSamplesDynamic(keywords: String) async throws -> [PriceSample] {
        let limit = config.maxListingsPerMarketplace

        switch config.selectionStrategy {
        case .mergeBoth:
            async let ca = ebay.searchActiveListings(keywords: keywords, marketplace: .ebayCA, limit: limit)
            async let us = ebay.searchActiveListings(keywords: keywords, marketplace: .ebayUS, limit: limit)
            return try await (ca + us)

        case .preferCAThenUS:
            let ca = try await ebay.searchActiveListings(keywords: keywords, marketplace: .ebayCA, limit: limit)
            if isWeak(ca) {
                let us = try await ebay.searchActiveListings(keywords: keywords, marketplace: .ebayUS, limit: limit)
                return ca + us
            }
            return ca

        case .preferUSThenCA:
            let us = try await ebay.searchActiveListings(keywords: keywords, marketplace: .ebayUS, limit: limit)
            if isWeak(us) {
                let ca = try await ebay.searchActiveListings(keywords: keywords, marketplace: .ebayCA, limit: limit)
                return us + ca
            }
            return us

        case .dynamic:
            async let ca = ebay.searchActiveListings(keywords: keywords, marketplace: .ebayCA, limit: limit)
            async let us = ebay.searchActiveListings(keywords: keywords, marketplace: .ebayUS, limit: limit)
            let (caRes, usRes) = try await (ca, us)

            let caScore = marketScore(samples: caRes)
            let usScore = marketScore(samples: usRes)

            if caScore >= usScore {
                if isWeak(caRes) { return caRes + usRes }
                return caRes
            } else {
                if isWeak(usRes) { return usRes + caRes }
                return usRes
            }
        }
    }

    private func isWeak(_ samples: [PriceSample]) -> Bool {
        samples.count < 8
    }

    private func marketScore(samples: [PriceSample]) -> Double {
        guard samples.count >= 5 else { return Double(samples.count) }
        let values = samples.map { $0.price.amount }
        let spread = iqr(values)
        let spreadPenalty = (spread == 0) ? 0.1 : min(5.0, Double((spread as NSDecimalNumber).doubleValue))
        return Double(samples.count) / spreadPenalty
    }

    // MARK: Filters + Conversion

    private func filterAndConvertToCAD(_ samples: [PriceSample]) async throws -> [PriceSample] {
        let usdToCad = try await fx.usdToCadRate()

        var out: [PriceSample] = []
        out.reserveCapacity(samples.count)

        for s in samples {
            var cadAmount: Decimal
            switch s.price.currency {
            case .cad:
                cadAmount = s.price.amount
            case .usd:
                cadAmount = s.price.amount * usdToCad
            }

            if config.hardMaxCAD > 0, cadAmount > config.hardMaxCAD { continue }
            if cadAmount <= 0 { continue }

            var copy = s
            copy.price = await MainActor.run { Money(amount: cadAmount, currency: .cad) }
            out.append(copy)
        }

        out = uniqueByAmountAndTitle(out)
        return out
    }

    private func uniqueByAmountAndTitle(_ samples: [PriceSample]) -> [PriceSample] {
        var seen = Set<String>()
        var out: [PriceSample] = []
        out.reserveCapacity(samples.count)

        for s in samples {
            let titleKey = (s.title ?? "").lowercased().prefix(40)
            let key = "\(s.price.amount)-\(titleKey)"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(s)
        }
        return out
    }

    // MARK: Stats

    private func median(_ values: [Decimal]) -> Decimal {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n/2] }
        let a = sorted[(n/2)-1]
        let b = sorted[n/2]
        return (a + b) / 2
    }

    private func quantile(_ values: [Decimal], q: Double) -> Decimal {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let pos = max(0.0, min(1.0, q)) * Double(sorted.count - 1)
        let lo = Int(floor(pos))
        let hi = Int(ceil(pos))
        if lo == hi { return sorted[lo] }
        let frac = Decimal(pos - floor(pos))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    private func iqr(_ values: [Decimal]) -> Decimal {
        guard values.count >= 4 else { return 0 }
        let q1 = quantile(values, q: 0.25)
        let q3 = quantile(values, q: 0.75)
        return q3 - q1
    }

    private func trimOutliers(_ samples: [PriceSample], quantile: Double) -> [PriceSample] {
        guard samples.count >= 10 else { return samples }
        let values = samples.map { $0.price.amount }
        let lo = quantileValue(values, q: quantile)
        let hi = quantileValue(values, q: 1.0 - quantile)
        return samples.filter { $0.price.amount >= lo && $0.price.amount <= hi }
    }

    private func quantileValue(_ values: [Decimal], q: Double) -> Decimal {
        quantile(values, q: q)
    }

    private func confidenceScore(n: Int, spread: Decimal) -> Double {
        if n <= 0 { return 0 }
        let nScore = min(1.0, Double(n) / 25.0)
        let spreadD = (spread as NSDecimalNumber).doubleValue
        let spreadScore = spreadD <= 0 ? 1.0 : max(0.0, 1.0 - min(1.0, spreadD / 40.0))
        return max(0.05, min(1.0, 0.15 + 0.55 * nScore + 0.30 * spreadScore))
    }
}

// MARK: - Helpers (integration)

public enum PricingBootstrap {

    /// Call this once (e.g., in your ViewModel init) to create the estimator.
    ///
    /// Required Info.plist keys (string):
    /// - EBAY_CLIENT_ID
    /// - EBAY_CLIENT_SECRET
    public static func makeEstimator(
        sandbox: Bool = false,
        strategy: MarketplaceSelectionStrategy = .dynamic,
        ocrThreshold: Double = 0.70
    ) -> CardiaPriceEstimator? {
        guard
            let clientId = Bundle.main.object(forInfoDictionaryKey: "EBAY_CLIENT_ID") as? String,
            let clientSecret = Bundle.main.object(forInfoDictionaryKey: "EBAY_CLIENT_SECRET") as? String,
            !clientId.isEmpty, !clientSecret.isEmpty
        else {
            return nil
        }

        let cfg = PricingConfig(
            selectionStrategy: strategy,
            minOCRConfidenceToSkipEbay: ocrThreshold
        )

        let tokenProvider = EbayOAuthTokenProvider(config: .init(clientId: clientId, clientSecret: clientSecret, sandbox: sandbox))
        let ebay = EbayBrowseClient(config: .init(sandbox: sandbox), tokenProvider: tokenProvider)

        let fx = BankOfCanadaValetFXProvider(maxAgeSeconds: cfg.fxMaxAgeSeconds)

        return CardiaPriceEstimator(config: cfg, ebay: ebay, fx: fx)
    }
}
