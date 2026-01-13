//
//  EbayPriceService.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation

final class EbayPriceService: PriceService {
    private let auth = EbayAuthService()
    private let browse = EbayBrowseService()

    func estimatePrice(for query: String) async throws -> Double? {
        let token = try await auth.getAppToken()
        let results = try await browse.searchActiveListings(query: query, limit: 25, token: token)

        let prices = results.compactMap { item -> Double? in
            guard let p = item.price else { return nil }
            return Double(p.value)
        }

        return PriceEstimator.median(prices)
    }
}

