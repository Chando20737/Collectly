//
//  PriceEstimator.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation

enum PriceEstimator {
    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        } else {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
    }
}

