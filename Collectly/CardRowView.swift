//
//  CardRowView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import UIKit

struct CardRowView: View {
    let item: CardItem
    let isEstimating: Bool
    let isFlashing: Bool

    var body: some View {
        HStack(spacing: 12) {
            CardThumbnailLarge(data: item.frontImageData)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if isEstimating {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Estimation…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    } else if let price = item.estimatedPriceCAD {
                        Text(String(format: "≈ %.0f $ CAD", price))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial)
                            .clipShape(Capsule())
                            .contentTransition(.numericText())
                            .transition(.scale.combined(with: .opacity))
                            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: price)
                    } else {
                        Text("Prix à estimer")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        // ✅ Flash visible: contour + “pop”
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isFlashing ? Color.green.opacity(0.9) : Color.clear, lineWidth: 3)
        }
        .scaleEffect(isFlashing ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: isFlashing)
    }
}

private struct CardThumbnailLarge: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.gray.opacity(0.2))
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 78, height: 78)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
