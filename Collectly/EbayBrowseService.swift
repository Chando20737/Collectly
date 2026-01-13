//
//  EbayBrowseService.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation

final class EbayBrowseService {

    struct SearchResponse: Decodable {
        let itemSummaries: [ItemSummary]?
    }

    struct ItemSummary: Decodable {
        let title: String?
        let price: Price?
        let itemWebUrl: String?

        struct Price: Decodable {
            let value: String
            let currency: String
        }
    }

    func searchActiveListings(query: String, limit: Int = 15, token: String) async throws -> [ItemSummary] {
        var comps = URLComponents(string: "https://api.ebay.com/buy/browse/v1/item_summary/search")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))
        ]

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(EbayConfig.marketplaceId, forHTTPHeaderField: "X-EBAY-C-MARKETPLACE-ID")

        let (data, resp) = try await URLSession.shared.data(for: request)

        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "EbayBrowse", code: 2, userInfo: [NSLocalizedDescriptionKey: "Search eBay refusé: \(text)"])
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.itemSummaries ?? []
    }
}

