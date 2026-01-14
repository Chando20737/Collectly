//
//  EditListingView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-14.
//
import SwiftUI

struct EditListingView: View {
    @Environment(\.dismiss) private var dismiss

    let listing: ListingCloud
    let repo: MarketplaceRepository

    private let maxTitleLength = 80

    @State private var title: String = ""
    @State private var descriptionText: String = ""

    @State private var buyNow: String = ""
    @State private var startingBid: String = ""

    @State private var isSaving = false
    @State private var errorText: String?

    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanDesc: String { descriptionText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        !isSaving && !cleanTitle.isEmpty && cleanTitle.count <= maxTitleLength
    }

    private var isAuction: Bool { listing.type != "fixedPrice" }
    private var canEditStartingBid: Bool { isAuction && listing.bidCount == 0 }

    var body: some View {
        Form {
            Section("Infos") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Titre annonce", text: $title)
                        .onChange(of: title) { _, newValue in
                            if newValue.count > maxTitleLength {
                                title = String(newValue.prefix(maxTitleLength))
                            }
                        }

                    HStack {
                        Text("Maximum \(maxTitleLength) caractères.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(min(title.count, maxTitleLength))/\(maxTitleLength)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(title.count >= maxTitleLength ? .orange : .secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Description (optionnelle)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    ZStack(alignment: .topLeading) {
                        if cleanDesc.isEmpty {
                            Text("Ex: état, détails, livraison, etc.")
                                .foregroundStyle(.secondary.opacity(0.7))
                                .padding(.top, 8)
                                .padding(.leading, 6)
                        }

                        TextEditor(text: $descriptionText)
                            .frame(minHeight: 90)
                            .padding(.horizontal, 2)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2))
                    )
                }
            }

            Section(isAuction ? "Encan" : "Prix (vente directe)") {
                if isAuction {
                    Text("La date de fin ne peut pas être modifiée après publication.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if canEditStartingBid {
                        TextField("Mise de départ (CAD)", text: $startingBid)
                            .keyboardType(.decimalPad)

                        Text("Tu peux modifier la mise de départ seulement s’il n’y a aucune mise.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Mise de départ verrouillée (il y a déjà des mises ou l’encan a commencé).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TextField("Prix (CAD)", text: $buyNow)
                        .keyboardType(.decimalPad)
                    Text("Ex: 25")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorText {
                Section("Erreur") {
                    Text(errorText).foregroundStyle(.red)
                }
            }

            Section {
                Button(isSaving ? "Enregistrement..." : "Enregistrer") {
                    save()
                }
                .disabled(!canSave)

                Button("Annuler", role: .cancel) {
                    dismiss()
                }
                .disabled(isSaving)
            }
        }
        .navigationTitle("Modifier")
        .onAppear {
            title = listing.title
            descriptionText = listing.descriptionText ?? ""

            if listing.type == "fixedPrice" {
                if let p = listing.buyNowPriceCAD {
                    buyNow = String(Int(p))
                }
            } else {
                if let s = listing.startingBidCAD {
                    startingBid = String(Int(s))
                }
            }

            if title.count > maxTitleLength {
                title = String(title.prefix(maxTitleLength))
            }
        }
    }

    private func save() {
        errorText = nil

        let finalTitle = cleanTitle
        if finalTitle.isEmpty {
            errorText = "Le titre est obligatoire."
            return
        }
        if finalTitle.count > maxTitleLength {
            errorText = "Le titre ne peut pas dépasser \(maxTitleLength) caractères."
            return
        }

        let finalDesc = cleanDesc
        let desc: String? = finalDesc.isEmpty ? nil : finalDesc

        var buyNowValue: Double? = nil
        var startingBidValue: Double? = nil

        if listing.type == "fixedPrice" {
            guard let p = toDouble(buyNow), p > 0 else {
                errorText = "Entre un prix valide (ex: 25)."
                return
            }
            buyNowValue = p
        } else {
            if canEditStartingBid {
                guard let s = toDouble(startingBid), s > 0 else {
                    errorText = "Entre une mise de départ valide (ex: 10)."
                    return
                }
                startingBidValue = s
            }
        }

        isSaving = true

        Task {
            do {
                try await repo.updateListing(
                    listingId: listing.id,
                    title: finalTitle,
                    descriptionText: desc,
                    typeString: listing.type,
                    buyNowPriceCAD: buyNowValue,
                    startingBidCAD: startingBidValue,
                    bidCount: listing.bidCount
                )

                await MainActor.run {
                    isSaving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func toDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        return Double(t.replacingOccurrences(of: ",", with: "."))
    }
}

