//
//  MyStatusChip.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-14.
//
import SwiftUI

/// Chip pour afficher un statut (Vendue / Terminée / En pause, etc.)
/// - Le texte devient BLANC automatiquement si le fond est jugé opaque
/// - backgroundOpacity / strokeOpacity viennent de ListingCloud.Badge
/// - isOverlayOnImage = true si affiché SUR une image
struct MyStatusChip: View {

    let text: String
    let systemImage: String
    let color: Color

    /// Opacité du fond
    let backgroundOpacity: Double

    /// Opacité du contour
    let strokeOpacity: Double

    /// Si affiché par-dessus une image
    let isOverlayOnImage: Bool

    init(
        text: String,
        systemImage: String,
        color: Color,
        backgroundOpacity: Double = 0.34,
        strokeOpacity: Double = 0.30,
        isOverlayOnImage: Bool = false
    ) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
        self.backgroundOpacity = backgroundOpacity
        self.strokeOpacity = strokeOpacity
        self.isOverlayOnImage = isOverlayOnImage
    }

    // MARK: - Automatic text color

    /// Si le fond est assez opaque → texte blanc
    private var effectiveTextColor: Color {
        let effectiveOpacity = isOverlayOnImage
            ? max(backgroundOpacity, 0.45)
            : backgroundOpacity

        return effectiveOpacity >= 0.45 ? .white : color
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))

            Text(text)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(effectiveTextColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(backgroundView)
        .overlay(
            Capsule()
                .stroke(
                    effectiveTextColor.opacity(strokeOpacity),
                    lineWidth: 1
                )
        )
        .clipShape(Capsule())
        .shadow(
            color: isOverlayOnImage ? Color.black.opacity(0.20) : .clear,
            radius: isOverlayOnImage ? 3 : 0,
            x: 0,
            y: isOverlayOnImage ? 1 : 0
        )
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundView: some View {
        if isOverlayOnImage {
            // ✅ SUR IMAGE:
            // material + scrim couleur plus opaque pour garantir la lisibilité
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .fill(color.opacity(max(backgroundOpacity, 0.45)))
                )
        } else {
            // ✅ INLINE:
            Capsule()
                .fill(color.opacity(backgroundOpacity))
        }
    }
}
