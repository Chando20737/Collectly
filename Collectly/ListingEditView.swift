//
//  ListingEditView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct ListingEditView: View {
    let listing: ListingCloud
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    private let maxTitleLength = 80

    @State private var title: String = ""
    @State private var descriptionText: String = ""
    @State private var priceText: String = ""

    @State private var isSaving = false
    @State private var errorText: String?

    @State private var showCancelConfirm = false

    private let service = MarketplaceService()

    private var isOwner: Bool { Auth.auth().currentUser?.uid == listing.sellerId }
    private var isFixedPrice: Bool { listing.type == "fixedPrice" }
    private var isAuction: Bool { listing.type != "fixedPrice" }

    private var initialTitle: String { listing.title }
    private var initialDesc: String { listing.descriptionText ?? "" }
    private var initialPrice: String {
        if let p = listing.buyNowPriceCAD { return String(format: "%.0f", p) }
        return ""
    }

    private var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanDesc: String {
        descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasUnsavedChanges: Bool {
        let t = cleanTitle
        let d = cleanDesc
        let p = priceText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isFixedPrice {
            return t != initialTitle || d != initialDesc || p != initialPrice
        } else {
            // auction: pas de prix modifiable ici
            return t != initialTitle || d != initialDesc
        }
    }

    private var titleCountText: String {
        "\(min(title.count, maxTitleLength))/\(maxTitleLength)"
    }

    private var canSave: Bool {
        isOwner &&
        !isSaving &&
        !cleanTitle.isEmpty &&
        cleanTitle.count <= maxTitleLength
    }

    var body: some View {
        NavigationStack {
            Form {

                if !isOwner {
                    Section {
                        Text("Tu ne peux pas modifier une annonce qui ne t’appartient pas.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Annonce") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Titre", text: $title)
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
                            Text(titleCountText)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(title.count >= maxTitleLength ? .orange : .secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $descriptionText)
                            .frame(minHeight: 90)
                    }
                }

                if isFixedPrice {
                    Section("Prix (vente fixe)") {
                        TextField("Prix (CAD)", text: $priceText)
                            .keyboardType(.decimalPad)

                        Text("Le prix est modifiable seulement pour une vente fixe.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if isAuction {
                    Section("Encan") {
                        if let end = listing.endDate {
                            Text("Fin: \(end.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Fin: non définie")
                                .foregroundStyle(.secondary)
                        }

                        Text("La date de fin d’un encan ne peut pas être modifiée.")
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
            .navigationTitle("Modifier")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") {
                        if hasUnsavedChanges {
                            showCancelConfirm = true
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "..." : "Enregistrer") { save() }
                        .disabled(!canSave)
                }
            }
            .alert("Annuler les modifications?", isPresented: $showCancelConfirm) {
                Button("Continuer à modifier", role: .cancel) {}
                Button("Annuler sans enregistrer", role: .destructive) { dismiss() }
            } message: {
                Text("Tes changements seront perdus.")
            }
            .onAppear {
                title = listing.title
                descriptionText = listing.descriptionText ?? ""
                if let p = listing.buyNowPriceCAD {
                    priceText = String(format: "%.0f", p)
                } else {
                    priceText = ""
                }
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

        isSaving = true

        let finalDesc = cleanDesc
        let desc: String? = finalDesc.isEmpty ? nil : finalDesc

        func toDouble(_ s: String) -> Double? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            return Double(t.replacingOccurrences(of: ",", with: "."))
        }
        let price = toDouble(priceText)

        Task {
            do {
                if isFixedPrice {
                    try await service.updateFixedPriceListing(
                        listingId: listing.id,
                        newTitle: finalTitle,
                        newDescription: desc,
                        newBuyNowPriceCAD: price
                    )
                } else {
                    // auction: titre + description SEULEMENT (pas de endDate)
                    try await updateAuctionTitleAndDescription(
                        listingId: listing.id,
                        newTitle: finalTitle,
                        newDescription: desc
                    )
                }

                await MainActor.run {
                    isSaving = false
                    onSaved()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    let ns = error as NSError
                    errorText = "Erreur: \(ns.localizedDescription)"
                    print("❌ Update error:", ns.domain, ns.code, ns)
                }
            }
        }
    }

    // MARK: - Auction safe update (no endDate changes)

    private func updateAuctionTitleAndDescription(
        listingId: String,
        newTitle: String,
        newDescription: String?
    ) async throws {
        let ref = Firestore.firestore()
            .collection("listings")
            .document(listingId)

        var payload: [String: Any] = [
            "title": newTitle,
            "updatedAt": Timestamp(date: Date())
        ]

        if let newDescription {
            payload["descriptionText"] = newDescription
        } else {
            payload["descriptionText"] = FieldValue.delete()
        }

        try await ref.setData(payload, merge: true)
    }
}

