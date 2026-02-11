//  PriceBadgeView.swift
//  Cardia (Collectly)
//
//  Small UI component to display estimated price + source + confidence.
//  Created by ChatGPT on 2026-01-21.
//

import SwiftUI

struct PriceBadgeView: View {
    let priceCAD: Double?
    let sourceLabel: String
    let confidence: Double?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let p = priceCAD {
                    Text(String(format: "≈ %.2f $ CAD", p))
                        .font(.headline)
                } else {
                    Text("—")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(sourceLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let c = confidence {
                        confidenceChip(c)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func confidenceChip(_ c: Double) -> some View {
        let clamped = max(0, min(1, c))
        let (text, color): (String, Color) = {
            if clamped >= 0.85 { return ("Haute", .green) }
            if clamped >= 0.70 { return ("Moyenne", .orange) }
            return ("Basse", .red)
        }()

        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .accessibilityLabel("Confiance \(text)")
    }
}
