//
//  MarketPlace.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import SwiftData

struct MarketplaceView: View {
    @Query(sort: \Listing.createdAt, order: .reverse) private var listings: [Listing]

    var body: some View {
        NavigationStack {
            List {
                if listings.isEmpty {
                    ContentUnavailableView(
                        "Aucune annonce",
                        systemImage: "tag",
                        description: Text("Publie une carte à vendre ou en encan.")
                    )
                } else {
                    ForEach(listings) { listing in
                        NavigationLink {
                            ListingDetailView(listing: listing)
                        } label: {
                            ListingRowView(listing: listing)
                        }
                    }
                }
            }
            .navigationTitle("Marketplace")
        }
    }
}

private struct ListingRowView: View {
    let listing: Listing

    var body: some View {
        HStack(spacing: 12) {
            CardThumbnail(data: listing.card?.frontImageData)

            VStack(alignment: .leading, spacing: 4) {
                Text(listing.title).font(.headline).lineLimit(2)

                switch listing.type {
                case .fixedPrice:
                    if let p = listing.buyNowPriceCAD {
                        Text(String(format: "Acheter maintenant: %.0f $ CAD", p))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                case .auction:
                    let current = listing.currentBidCAD ?? listing.startingBidCAD ?? 0
                    Text(String(format: "Encan: %.0f $ CAD • %d mises", current, listing.bidCount))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("Statut: \(listing.statusRaw)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}

