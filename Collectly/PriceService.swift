//
//  PriceService.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation

protocol PriceService {
    func estimatePrice(for query: String) async throws -> Double?
}

