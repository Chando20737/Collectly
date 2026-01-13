//
//  MockPriceService.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation

final class MockPriceService: PriceService {
    func estimatePrice(for query: String) async throws -> Double? {
        // Simule un délai réseau
        try await Task.sleep(nanoseconds: 600_000_000)

        // Prix bidon mais réaliste
        return Double(Int.random(in: 8...320))
    }
}
