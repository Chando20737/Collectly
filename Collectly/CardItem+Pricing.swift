//  CardItem+Pricing.swift
//  Cardia (Collectly)
//
//  Pricing helpers (v1): source, confidence, refresh policy.
//  Created by ChatGPT on 2026-01-21.
//

import Foundation

// MARK: - Pricing source (stored as raw String for SwiftData simplicity)
enum CardiaPriceSource: String {
    case local       // comparables/cache local
    case ebay        // eBay lookup
    case heuristic   // estimation fallback
    case manual      // user override
}

extension CardItem {

    var priceSource: CardiaPriceSource? {
        get {
            guard let raw = priceSourceRaw, let s = CardiaPriceSource(rawValue: raw) else { return nil }
            return s
        }
        set { priceSourceRaw = newValue?.rawValue }
    }

    var priceSourceLabelFR: String {
        switch priceSource {
        case .local: return "Comparables"
        case .ebay: return "eBay"
        case .heuristic: return "Estimation"
        case .manual: return "Manuel"
        case .none: return "—"
        }
    }

    /// True if the stored price is missing or older than `maxAgeDays`.
    func needsPriceRefresh(maxAgeDays: Int = 7) -> Bool {
        guard estimatedPriceCAD != nil else { return true }
        guard let last = lastPriceUpdate else { return true }
        let age = Date().timeIntervalSince(last)
        return age > (Double(maxAgeDays) * 24.0 * 60.0 * 60.0)
    }

    /// Convenience: set manual price and mark metadata consistently.
    func setManualPriceCAD(_ value: Double?) {
        if let v = value {
            estimatedPriceCAD = v
            priceSource = .manual
            priceConfidence = 1.0
            lastPriceUpdate = Date()
        } else {
            estimatedPriceCAD = nil
            priceSource = nil
            priceConfidence = nil
            lastPriceUpdate = nil
        }
    }
}
