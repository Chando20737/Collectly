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

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)

            Text(text)
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }
}

