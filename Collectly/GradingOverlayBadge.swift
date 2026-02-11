//
//  GradingOverlayBadge.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-12.
//
import SwiftUI

/// Badge uniforme: texte bleu + fond gris, capsule, prêt à déborder (offset appliqué dans les vues)
struct GradingOverlayBadge: View {
    let label: String
    var compact: Bool = false

    var body: some View {
        Text(label)
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(Color.blue)
            .lineLimit(1)
            .minimumScaleFactor(0.80)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 5 : 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.systemGray5))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.black.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
            .allowsHitTesting(false)
    }
}
