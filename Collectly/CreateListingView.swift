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

    // ✅ HYBRIDE: carte optionnelle
    let card: CardItem?

    private let maxTitleLength = 80

    // ✅ Minimum encan = 8 heures
    private let minAuctionHours: Double = 8
    private let defaultAuctionDays: Int = 3

    // ✅ NOUVEAU: minimum mise de départ
    private let minStartingBidCAD: Double = 2

    @State private var type: ListingType = .fixedPrice
    @State private var title: String = ""
    @State private var descriptionText: String = ""

    @State private var buyNow: String = ""
    @State private var startingBid: String = ""   // (on laisse l’utilisateur entrer)

    // ✅ Date/Time encan (géré via pickers custom)
    @State private var endDate: Date =
        Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()

    @State private var endDateOnly: Date = Date()
    @State private var endHour: Int = Calendar.current.component(.hour, from: Date())
    @State private var endMinuteIndex: Int = 0 // 0->00, 1->15, 2->30, 3->45

    @State private var isPublishing = false
    @State private var errorText: String?

    private let marketplace = MarketplaceService()
    private let repo = MarketplaceRepository()

    private let quarterMinutes: [Int] = [0, 15, 30, 45]

    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanDesc: String { descriptionText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var titleCountText: String { "\(min(title.count, maxTitleLength))/\(maxTitleLength)" }

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
            setEndDate(minAuctionEndDate)
        }
    }

    // MARK: - Preview values

    private var previewBuyNow: Double? { (type == .fixedPrice) ? toDouble(buyNow) : nil }
    private var previewStartBid: Double? { (type == .auction) ? toDouble(startingBid) : nil }

    // MARK: - UI helpers

    private var linkedCardTitle: String? { card?.title }
    private var linkedCardImageData: Data? { card?.frontImageData }
    private var navTitle: String { card == nil ? "Créer une annonce" : "Mettre en vente" }

    // MARK: - End date helpers

    private func roundedToQuarter(_ date: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let m = comps.minute ?? 0
        let rounded = [0, 15, 30, 45].min(by: { abs($0 - m) < abs($1 - m) }) ?? 0
        comps.minute = rounded
        comps.second = 0
        return cal.date(from: comps) ?? date
    }

    private func setEndDate(_ date: Date) {
        let cal = Calendar.current
        let d = roundedToQuarter(date)
        endDate = d

        endDateOnly = cal.startOfDay(for: d)
        endHour = cal.component(.hour, from: d)
        let m = cal.component(.minute, from: d)
        endMinuteIndex = quarterMinutes.firstIndex(of: m) ?? 0
    }

    private func rebuildEndDateFromPickers() {
        let cal = Calendar.current
        let base = endDateOnly
        let minute = quarterMinutes[safe: endMinuteIndex] ?? 0

        var comps = cal.dateComponents([.year, .month, .day], from: base)
        comps.hour = endHour
        comps.minute = minute
        comps.second = 0

        let rebuilt = cal.date(from: comps) ?? endDate
        endDate = rebuilt

        if type == .auction, endDate < minAuctionEndDate {
            setEndDate(minAuctionEndDate)
        }
    }

    var body: some View {
        Form {

            if let c = card {
                Section("Carte liée") {
                    HStack(spacing: 12) {
                        CardThumbnail(data: c.frontImageData)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.title)
                                .font(.headline)
                                .lineLimit(2)
                            Text("Cette annonce sera liée à ta collection.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section("Annonce libre") {
                    Text("Cette annonce n’est pas liée à une carte de ta collection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Type") {
                Picker("Type", selection: $type) {
                    Text("Vente directe").tag(ListingType.fixedPrice)
                    Text("Encan").tag(ListingType.auction)
                }
                .pickerStyle(.segmented)
                .onChange(of: type) { _, _ in
                    ensureAuctionEndDateIsValidIfNeeded()
                    // Petit coup de pouce UX: si encan et champ vide, on suggère 2$
                    if type == .auction, startingBid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        startingBid = "2"
                    }
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
                    imageData: linkedCardImageData,
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

                    Text("Minimum: \(Int(minStartingBidCAD)) $ CAD")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

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
                                setEndDate(Date().addingTimeInterval(24 * 60 * 60))
                            }
                            .font(.footnote.weight(.semibold))

                            Spacer()

                            Text("Min: \(minAuctionEndDateText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    Section {
                        DatePicker(
                            "Fin (date)",
                            selection: $endDateOnly,
                            in: Calendar.current.startOfDay(for: minAuctionEndDate)...,
                            displayedComponents: [.date]
                        )
                        .onChange(of: endDateOnly) { _, _ in rebuildEndDateFromPickers() }

                        HStack {
                            Text("Heure")
                            Spacer()
                            Picker("Heure", selection: $endHour) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d", h)).tag(h)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(width: 90, height: 110)
                            .clipped()
                            .onChange(of: endHour) { _, _ in rebuildEndDateFromPickers() }

                            Text(":")
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            Picker("Minutes", selection: $endMinuteIndex) {
                                ForEach(0..<quarterMinutes.count, id: \.self) { idx in
                                    Text(String(format: "%02d", quarterMinutes[idx])).tag(idx)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(width: 90, height: 110)
                            .clipped()
                            .onChange(of: endMinuteIndex) { _, _ in rebuildEndDateFromPickers() }
                        }

                        HStack {
                            Text("Fin")
                            Spacer()
                            Text(endDate.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
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
        .navigationTitle(navTitle)
        .onAppear {
            if title.isEmpty, let t = linkedCardTitle { title = t }
            if title.count > maxTitleLength { title = String(title.prefix(maxTitleLength)) }

            setEndDate(endDate)
            ensureAuctionEndDateIsValidIfNeeded()
            setEndDate(endDate)

            if type == .auction, startingBid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                startingBid = "2"
            }
        }
        .onChange(of: type) { _, _ in
            if type == .auction {
                ensureAuctionEndDateIsValidIfNeeded()
                setEndDate(endDate)
                if startingBid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    startingBid = "2"
                }
            }
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
            guard let start = toDouble(startingBid) else {
                errorText = "Entre une mise de départ valide (ex: 2)."
                return
            }
            guard start >= minStartingBidCAD else {
                errorText = "La mise de départ doit être d’au moins \(Int(minStartingBidCAD)) $ CAD."
                startingBid = String(Int(minStartingBidCAD))
                return
            }

            if endDate < minAuctionEndDate {
                errorText = "Un encan doit durer au moins 8 heures."
                setEndDate(minAuctionEndDate)
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
                if let card {
                    try await marketplace.createListingFromCollection(
                        from: card,
                        title: finalTitle,
                        description: desc,
                        type: type,
                        buyNowPriceCAD: buyNowPrice,
                        startingBidCAD: startBid,
                        endDate: end
                    )
                } else {
                    try await repo.createFreeListing(
                        title: finalTitle,
                        descriptionText: desc,
                        type: type,
                        buyNowPriceCAD: buyNowPrice,
                        startingBidCAD: startBid,
                        endDate: end
                    )
                }

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

    private func toDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        return Double(t.replacingOccurrences(of: ",", with: "."))
    }
}

// MARK: - Preview Row (inchangé)

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
                    let countText = (bidCount <= 1) ? "\(bidCount) mise" : "\(bidCount) mises"
                    Text(String(format: "Mise: %.0f $ CAD • %@", start, countText))
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

// MARK: - Safe array access

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}

