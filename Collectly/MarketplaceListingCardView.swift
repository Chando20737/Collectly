//
//  MarketplaceListingCardView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-14.
//
import SwiftUI

// ✅ Carte UI Marketplace pour une annonce (ListingCloud)
// - Badge PSA (ou grading) en haut à droite (déjà chez toi)
// - Badge "Se termine bientôt" en haut à droite SOUS le grading (donc pas de conflit)
struct MarketplaceListingCardView: View {

    let listing: ListingCloud

    // ✅ Réglage: "bientôt" = moins de 24h
    private let endingSoonThreshold: TimeInterval = 24 * 60 * 60

    private var isAuction: Bool { listing.type == "auction" }

    private var isEndingSoon: Bool {
        guard isAuction else { return false }
        guard listing.status == "active" else { return false }
        guard let end = listing.endDate else { return false }

        let remaining = end.timeIntervalSinceNow
        return remaining > 0 && remaining <= endingSoonThreshold
    }

    private var primaryPriceLine: String {
        if listing.type == "fixedPrice" {
            let p = listing.buyNowPriceCAD ?? 0
            return String(format: "%.0f $ CAD", p)
        } else {
            let current = listing.currentBidCAD ?? listing.startingBidCAD ?? 0
            return String(format: "Mise: %.0f $ CAD • %@", current, miseText(listing.bidCount))
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {

            // ✅ CARD
            VStack(alignment: .leading, spacing: 10) {

                // IMAGE
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.secondary.opacity(0.10))

                    if let urlString = listing.imageUrl,
                       let url = URL(string: urlString) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            case .failure:
                                Image(systemName: "photo")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            @unknown default:
                                Image(systemName: "photo")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 140)

                // TITRE
                Text(listing.title.isEmpty ? "Annonce" : listing.title)
                    .font(.headline)
                    .lineLimit(2)

                // TYPE + PRIX / MISE
                HStack(spacing: 8) {
                    typePill

                    Spacer()

                    Text(primaryPriceLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Fin encan (optionnel mais utile)
                if isAuction, let end = listing.endDate {
                    Text("Fin: \(end.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.secondary.opacity(0.12))
            )

            // ✅ TOP-RIGHT BADGES (pile verticale)
            VStack(alignment: .trailing, spacing: 6) {

                // 1) ✅ Badge grading (PSA) — déjà chez toi, on le garde en premier
                if listing.shouldShowGradingBadge, let label = listing.gradingLabel {
                    BadgePill(
                        text: label,
                        systemImage: "checkmark.seal.fill",
                        style: .blue
                    )
                }

                // 2) ✅ Badge "Se termine bientôt" (SOUS PSA)
                if isEndingSoon {
                    BadgePill(
                        text: "Se termine bientôt",
                        systemImage: "clock.fill",
                        style: .orange
                    )
                }
            }
            .padding(10)
        }
    }

    private var typePill: some View {
        if listing.type == "auction" {
            return BadgePill(text: "Encan", systemImage: "hammer.fill", style: .gray)
        } else {
            return BadgePill(text: "Acheter", systemImage: "tag.fill", style: .gray)
        }
    }

    // MARK: - French pluralization
    private func miseText(_ count: Int) -> String {
        return count <= 1 ? "\(count) mise" : "\(count) mises"
    }
}

// MARK: - Small reusable pill

private struct BadgePill: View {

    enum Style {
        case gray
        case blue
        case orange
    }

    let text: String
    let systemImage: String
    let style: Style

    private var bg: Color {
        switch style {
        case .gray: return .secondary.opacity(0.14)
        case .blue: return .blue.opacity(0.18)
        case .orange: return .orange.opacity(0.20)
        }
    }

    private var fg: Color {
        switch style {
        case .gray: return .secondary
        case .blue: return .blue
        case .orange: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(bg)
        .foregroundStyle(fg)
        .clipShape(Capsule())
    }
}

