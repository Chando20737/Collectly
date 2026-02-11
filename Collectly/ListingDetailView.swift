//
//  ListingDetailView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import SwiftData
import UIKit

struct ListingDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var listing: Listing

    @State private var showBidSheet = false
    @State private var showBuyAlert = false

    var body: some View {
        Form {
            Section("Annonce") {
                Text(listing.title)
                if let d = listing.descriptionText, !d.isEmpty {
                    Text(d).foregroundStyle(.secondary)
                }
                Text("Type: \(listing.typeRaw)")
                Text("Statut: \(listing.statusRaw)")
            }

            Section("Carte") {
                if let data = listing.card?.frontImageData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text("Aucune image").foregroundStyle(.secondary)
                }
            }

            Section("Prix") {
                switch listing.type {
                case .fixedPrice:
                    if let p = listing.buyNowPriceCAD {
                        Text(String(format: "%.0f $ CAD", p))
                    }
                case .auction:
                    let current = listing.currentBidCAD ?? listing.startingBidCAD ?? 0
                    Text(String(format: "Mise actuelle: %.0f $ CAD", current))
                    Text("Nombre de mises: \(listing.bidCount)")
                    if let end = listing.endDate {
                        Text("Fin: \(end.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if listing.status == .active {
                    switch listing.type {
                    case .fixedPrice:
                        Button("Acheter maintenant (mock)") {
                            showBuyAlert = true
                        }
                    case .auction:
                        Button("Miser (mock)") {
                            showBidSheet = true
                        }
                    }
                } else {
                    Text("Annonce terminée.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Détail")
        .alert("Achat simulé", isPresented: $showBuyAlert) {
            Button("Confirmer") {
                listing.markSold()
                let gen = UINotificationFeedbackGenerator()
                gen.notificationOccurred(.success)
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Dans le MVP, l’achat est simulé. Plus tard: Stripe + expédition.")
        }
        .sheet(isPresented: $showBidSheet) {
            PlaceBidView(listing: listing)
        }
    }
}

private struct PlaceBidView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var listing: Listing

    @State private var bidText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Ta mise") {
                    TextField("Montant (CAD)", text: $bidText)
                        .keyboardType(.decimalPad)
                }
                Section {
                    Button("Confirmer la mise") {
                        placeBid()
                    }
                }
            }
            .navigationTitle("Miser")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    private func placeBid() {
        let bid = Double(bidText.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard bid > 0 else { return }

        let current = listing.currentBidCAD ?? listing.startingBidCAD ?? 0
        guard bid > current else { return }

        listing.currentBidCAD = bid
        listing.bidCount += 1

        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(.success)
        dismiss()
    }
}

