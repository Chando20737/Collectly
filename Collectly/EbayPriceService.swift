import Foundation

/// Minimal helper used by the app to fetch quick comps / prices.
///
/// NOTE: The Browse API search returns *active* listings (not "sold").
/// For a price estimate this is often good enough as a first iteration.
/// If you later want true sold comps, you can switch to other eBay data sources.
final class EbayPriceService {

    static let shared = EbayPriceService()
    private init() {}

    private let auth = EbayAuthService.shared
    private let browse = EbayBrowseService()

    struct PriceResult {
        let average: Double?
        let median: Double?
        let min: Double?
        let max: Double?
        let sampleCount: Int
        let currency: String?
    }

    // Browse API models price.value as a String.
    // Be tolerant to commas and whitespace.
    private func parsePrice(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Normalize decimal separator.
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")

        // Prefer a strict POSIX parse.
        let nf = NumberFormatter()
        nf.locale = Locale(identifier: "en_US_POSIX")
        nf.numberStyle = .decimal
        if let n = nf.number(from: normalized) {
            return n.doubleValue
        }
        return Double(normalized)
    }

    /// Very simple: search and compute stats on price.value.
    /// - Parameters:
    ///   - query: e.g. "2022-23 Upper Deck Young Guns Juraj Slafkovsky 451"
    ///   - limit: number of results to consider
    func fetchPriceEstimate(query: String, limit: Int = 40) async throws -> PriceResult {
        let token = try await auth.getAppAccessToken()

        var comps: [Double] = []
        var currency: String? = nil

        // Use Browse search (active listings)
        let items = try await browse.searchActiveListings(
            query: query,
            limit: min(max(limit, 1), 200),
            token: token
        )

        for item in items {
            if let raw = item.price?.value,
               let v = parsePrice(raw) {
                comps.append(v)
                currency = currency ?? item.price?.currency
            }
        }

        comps.sort()
        let n = comps.count
        guard n > 0 else {
            return PriceResult(average: nil, median: nil, min: nil, max: nil, sampleCount: 0, currency: currency)
        }

        let sum = comps.reduce(0.0, +)
        let avg = sum / Double(n)
        let med: Double
        if n % 2 == 1 {
            med = comps[n/2]
        } else {
            med = (comps[n/2 - 1] + comps[n/2]) / 2.0
        }

        return PriceResult(
            average: avg,
            median: med,
            min: comps.first,
            max: comps.last,
            sampleCount: n,
            currency: currency
        )
    }
}
