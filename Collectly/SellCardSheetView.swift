//
//  SellCardSheetView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-14.
//
import SwiftUI

struct SellCardSheetView: View {
    let card: CardItem
    let existing: ListingMini?
    let onSubmit: (_ title: String,
                   _ description: String?,
                   _ type: ListingType,
                   _ buyNow: Double?,
                   _ startBid: Double?,
                   _ endDate: Date?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var descriptionText: String = ""

    @State private var type: ListingType = .fixedPrice

    @State private var buyNowText: String = ""
    @State private var startBidText: String = ""
    @State private var endDate: Date = Date().addingTimeInterval(60 * 60 * 24)

    @State private var errorText: String? = nil

    // ✅ Minimum 8 heures pour un encan
    private let minAuctionDurationSeconds: TimeInterval = 8 * 60 * 60

    var body: some View {
        NavigationStack {
            Form {
                Section("Carte") {
                    Text(card.title)
                        .font(.headline)
                }

                Section("Annonce") {
                    TextField("Titre de l’annonce", text: $title)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(true)

                    TextField("Description (optionnel)", text: $descriptionText, axis: .vertical)
                        .lineLimit(3...7)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(true)
                }

                Section("Type") {
                    Picker("Type", selection: $type) {
                        Text("Prix fixe").tag(ListingType.fixedPrice)
                        Text("Encan").tag(ListingType.auction)
                    }
                    .pickerStyle(.segmented)
                }

                if type == .fixedPrice {
                    Section("Prix fixe") {
                        TextField("Prix (CAD)", text: $buyNowText)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)

                        Text("Ex: 25")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Encan") {
                        TextField("Mise de départ (CAD)", text: $startBidText)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)

                        DatePicker("Fin", selection: $endDate, displayedComponents: [.date, .hourAndMinute])

                        Text("✅ Minimum: 8 heures. La fin ne pourra plus être modifiée après publication.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorText {
                    Section("Erreur") {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Mettre en vente" : "Modifier la vente")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Publier") { submit() }
                }
            }
            .onAppear { presetFromExisting() }
        }
    }

    private func presetFromExisting() {
        if title.trimmedLocal.isEmpty {
            title = card.title
        }

        if let existing {
            type = (existing.type == "auction") ? .auction : .fixedPrice

            if let p = existing.buyNowPriceCAD {
                buyNowText = String(format: "%.2f", p)
            }

            if let s = existing.startingBidCAD {
                startBidText = String(format: "%.2f", s)
            }

            if let end = existing.endDate {
                endDate = end
            } else {
                endDate = Date().addingTimeInterval(60 * 60 * 24)
            }
        } else {
            // défaut pour création
            if endDate <= Date() {
                endDate = Date().addingTimeInterval(60 * 60 * 24)
            }
        }
    }

    private func submit() {
        errorText = nil

        let cleanTitle = title.trimmedLocal
        if cleanTitle.isEmpty {
            errorText = "Le titre est requis."
            return
        }

        let cleanDesc = descriptionText.trimmedLocal
        let desc: String? = cleanDesc.isEmpty ? nil : cleanDesc

        func toDouble(_ s: String) -> Double? {
            let t = s.trimmedLocal
            if t.isEmpty { return nil }
            return Double(t.replacingOccurrences(of: ",", with: "."))
        }

        if type == .fixedPrice {
            guard let price = toDouble(buyNowText), price > 0 else {
                errorText = "Entre un prix valide."
                return
            }

            onSubmit(cleanTitle, desc, .fixedPrice, price, nil, nil)
            dismiss()
        } else {
            guard let start = toDouble(startBidText), start >= 0 else {
                errorText = "Entre une mise de départ valide."
                return
            }

            let minEnd = Date().addingTimeInterval(minAuctionDurationSeconds)
            if endDate < minEnd {
                errorText = "La fin de l’encan doit être au moins 8 heures dans le futur."
                return
            }

            onSubmit(cleanTitle, desc, .auction, nil, start, endDate)
            dismiss()
        }
    }
}

// MARK: - Helpers

private extension String {
    var trimmedLocal: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

