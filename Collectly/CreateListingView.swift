//
//  CreateListingView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import SwiftData

struct CreateListingView: View {
    @Environment(\.dismiss) private var dismiss

    let card: CardItem

    private let maxTitleLength = 80

    // ✅ Minimum encan = 8 heures
    private let minAuctionHours: Double = 8
    private let defaultAuctionDays: Int = 3

    @State private var type: ListingType = .fixedPrice
    @State private var title: String = ""
    @State private var descriptionText: String = ""

    @State private var buyNow: String = ""
    @State private var startingBid: String = ""

    // ✅ Valeur par défaut (3 jours)
    @State private var endDate: Date =
        Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()

    @State private var isPublishing = false
    @State private var errorText: String?

    private let marketplace = MarketplaceService()

    private var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanDesc: String {
        descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var titleCountText: String {
        "\(min(title.count, maxTitleLength))/\(maxTitleLength)"
    }

    private var canPublish: Bool {
        !isPublishing && !cleanTitle.isEmpty && cleanTitle.count <= maxTitleLength
    }

    // MARK: - Dates (Auction min)

    private var minAuctionEndDate: Date {
        Date().addingTimeInterval(minAuctionHours * 60 * 60)
    }

    private var minAuctionEndDateText: String {
        minAuctionEndDate.formatted(date: .abbreviated, time: .shortened)
    }

    private func ensureAuctionEndDateIsValidIfNeeded() {
        guard type == .auction else { return }
        if endDate < minAuctionEndDate {
            endDate = minAuctionEndDate
        }
    }

    // MARK: - Preview values

    private var previewBuyNow: Double? { (type == .fixedPrice) ? toDouble(buyNow) : nil }
    private var previewStartBid: Double? { (type == .auction) ? toDouble(startingBid) : nil }

    var body: some View {
        Form {

            Section("Type") {
                Picker("Type", selection: $type) {
                    Text("Vente directe").tag(ListingType.fixedPrice)
                    Text("Encan").tag(ListingType.auction)
                }
                .pickerStyle(.segmented)
                .onChange(of: type) { _, _ in
                    // ✅ Si l’utilisateur bascule vers encan, on force un endDate valide
                    ensureAuctionEndDateIsValidIfNeeded()
                }
            }

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
                        Text(titleCountText)
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

            Section("Aperçu dans Marketplace") {
                MarketplaceDraftPreviewRow(
                    imageData: card.frontImageData,
                    type: type,
                    title: cleanTitle,
                    buyNowPrice: previewBuyNow,
                    startingBid: previewStartBid,
                    bidCount: 0,
                    endDate: (type == .auction) ? endDate : nil
                )
                .padding(.vertical, 6)

                Text("C’est un aperçu visuel. Les prix/mises reflètent ce que tu entres ici.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(type == .fixedPrice ? "Prix (vente directe)" : "Encan") {
                if type == .fixedPrice {

                    TextField("Prix (CAD)", text: $buyNow)
                        .keyboardType(.decimalPad)

                    Text("Ex: 25")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                } else {

                    TextField("Mise de départ (CAD)", text: $startingBid)
                        .keyboardType(.decimalPad)

                    // ✅ UX: rappel du minimum + raccourci 24h
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                            Text("Minimum: 8 heures (à partir de maintenant)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        HStack(spacing: 10) {
                            Button("Mettre +24 h") {
                                endDate = Date().addingTimeInterval(24 * 60 * 60)
                                ensureAuctionEndDateIsValidIfNeeded()
                            }
                            .font(.footnote.weight(.semibold))

                            Spacer()

                            Text("Min: \(minAuctionEndDateText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    // ✅ DatePicker avec minDate = now + 8h
                    DatePicker(
                        "Fin",
                        selection: $endDate,
                        in: minAuctionEndDate...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .onChange(of: endDate) { _, _ in
                        // Double sécurité (même si DatePicker empêche déjà)
                        ensureAuctionEndDateIsValidIfNeeded()
                    }

                    Text("La date de fin ne pourra plus être modifiée après publication.")
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

            Section {
                Button(isPublishing ? "Publication..." : "Publier") {
                    publishToCloud()
                }
                .disabled(!canPublish)

                Button("Annuler", role: .cancel) {
                    dismiss()
                }
                .disabled(isPublishing)
            }
        }
        .navigationTitle("Créer une annonce")
        .onAppear {
            if title.isEmpty { title = card.title }
            if title.count > maxTitleLength {
                title = String(title.prefix(maxTitleLength))
            }
            ensureAuctionEndDateIsValidIfNeeded()
        }
    }

    // MARK: - Publish

    private func publishToCloud() {
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

        if type == .fixedPrice {
            guard let price = toDouble(buyNow), price > 0 else {
                errorText = "Entre un prix valide (ex: 25)."
                return
            }
        } else {
            guard let start = toDouble(startingBid), start > 0 else {
                errorText = "Entre une mise de départ valide (ex: 10)."
                return
            }

            // ✅ Validation UX: minimum 8h
            if endDate < minAuctionEndDate {
                errorText = "Un encan doit durer au moins 8 heures."
                endDate = minAuctionEndDate
                return
            }
        }

        isPublishing = true

        let finalDesc = cleanDesc
        let desc: String? = finalDesc.isEmpty ? nil : finalDesc

        let buyNowPrice = (type == .fixedPrice) ? toDouble(buyNow) : nil
        let startBid = (type == .auction) ? toDouble(startingBid) : nil
        let end = (type == .auction) ? endDate : nil

        Task {
            do {
                try await marketplace.createListingFromCollection(
                    from: card,
                    title: finalTitle,
                    description: desc,
                    type: type,
                    buyNowPriceCAD: buyNowPrice,
                    startingBidCAD: startBid,
                    endDate: end
                )

                await MainActor.run {
                    isPublishing = false
                    dismiss()
                }
            } catch let err as MarketplaceError {
                await MainActor.run {
                    isPublishing = false
                    switch err {
                    case .alreadyListed:
                        errorText = "Cette carte est déjà en vente. Va dans « Mes annonces »."
                    default:
                        errorText = err.localizedDescription
                    }
                }
            } catch {
                await MainActor.run {
                    isPublishing = false
                    errorText = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Helpers

    private func toDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        return Double(t.replacingOccurrences(of: ",", with: "."))
    }
}

// MARK: - Preview Row (dans le même fichier)

private struct MarketplaceDraftPreviewRow: View {
    let imageData: Data?
    let type: ListingType
    let title: String
    let buyNowPrice: Double?
    let startingBid: Double?
    let bidCount: Int
    let endDate: Date?

    @State private var isPressed = false

    private var isAuction: Bool { type == .auction }
    private var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 12) {
            CardThumbnail(data: imageData)

            VStack(alignment: .leading, spacing: 6) {
                Text(hasTitle ? title : "Titre de l’annonce")
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(hasTitle ? .primary : .secondary)

                HStack(spacing: 6) {
                    if isAuction {
                        pill(text: "Encan", systemImage: "hammer.fill")
                    } else {
                        pill(text: "Acheter maintenant", systemImage: "tag.fill")
                    }
                }

                if isAuction {
                    let start = startingBid ?? 0
                    Text(String(format: "Mise: %.0f $ CAD • %d mises", start, bidCount))
                        .foregroundStyle(.secondary)

                    if let endDate {
                        Text("Temps restant: \(timeRemainingText(until: endDate))")
                            .font(.footnote)
                            .foregroundStyle(endDate <= Date() ? .red : .secondary)

                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("Se termine le \(endDate.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Temps restant: non défini")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if let p = buyNowPrice {
                        Text(String(format: "%.0f $ CAD", p))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Prix non défini")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isPressed ? Color.secondary.opacity(0.15) : Color.secondary.opacity(0.06))
        )
        .scaleEffect(isPressed ? 0.985 : 1)
        .animation(.easeOut(duration: 0.15), value: isPressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        isPressed = false
                    }
                }
        )
    }

    private func pill(text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(text)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(.secondary)
        .background(.secondary.opacity(0.12))
        .clipShape(Capsule())
    }

    private func timeRemainingText(until end: Date) -> String {
        let now = Date()
        if end <= now { return "Terminé" }

        let diff = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: end)
        let d = diff.day ?? 0
        let h = diff.hour ?? 0
        let m = diff.minute ?? 0

        if d > 0 { return "\(d) j \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        return "\(max(m, 1)) min"
    }
}

