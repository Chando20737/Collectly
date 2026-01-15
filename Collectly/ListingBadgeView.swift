//
//  ListingBadgeView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-11.
//
import SwiftUI

struct ListingBadgeView: View {
    let text: String
    let systemImage: String
    let color: Color

    /// ✅ Par défaut (pour compatibilité avec tous les anciens appels)
    var backgroundOpacity: Double = 0.15
    var strokeOpacity: Double = 0.30

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)

            Text(text)
                .font(.caption2)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(color)
        .background(
            Capsule().fill(color.opacity(backgroundOpacity))
        )
        .overlay(
            Capsule().stroke(color.opacity(strokeOpacity), lineWidth: 1)
        )
        .clipShape(Capsule())
    }
}

