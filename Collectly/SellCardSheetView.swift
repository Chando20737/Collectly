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

    // ✅ Date finale envoyée au submit (doit respecter 00/15/30/45)
    @State private var endDate: Date = Date().addingTimeInterval(60 * 60 * 24)

    // ✅ Pickers séparés (date + heure + minutes quart d’heure)
    @State private var endDateOnly: Date = Calendar.current.startOfDay(for: Date().addingTimeInterval(60 * 60 * 24))
    @State private var endHour: Int = Calendar.current.component(.hour, from: Date())
    @State private var endMinuteIndex: Int = 0

    @State private var errorText: String? = nil

    // ✅ Minimum 8 heures pour un encan
    private let minAuctionDurationSeconds: TimeInterval = 8 * 60 * 60

    // ✅ Minutes autorisées
    private let quarterMinutes: [Int] = [0, 15, 30, 45]

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
                    .onChange(of: type) { _, newType in
                        if newType == .auction {
                            // Quand on passe en encan, on s’assure d’avoir une date valide et alignée sur 00/15/30/45
                            alignPickersFromEndDate(roundUpToQuarter: true)
                            ensureMinAuctionEndDate()
                        }
                    }
                }

                if type == .fixedPrice {
                    Section("Prix fixe") {
                        TextField("Prix (CAD)", text: $buyNowText)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    }
                } else {
                    Section("Encan") {
                        TextField("Mise de départ (CAD)", text: $startBidText)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)

                        // ✅ Date (jour seulement)
                        DatePicker(
                            "Date de fin",
                            selection: $endDateOnly,
                            in: Calendar.current.startOfDay(for: minAuctionEndDate())...,
                            displayedComponents: [.date]
                        )
                        .onChange(of: endDateOnly) { _, _ in
                            rebuildEndDateFromPickers()
                            ensureMinAuctionEndDate()
                        }

                        // ✅ Heure + Minutes (00/15/30/45)
                        HStack {
                            Text("Heure")
                            Spacer()

                            Picker("Heure", selection: $endHour) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d", h)).tag(h)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(width: 90, height: 120)
                            .clipped()
                            .onChange(of: endHour) { _, _ in
                                rebuildEndDateFromPickers()
                                ensureMinAuctionEndDate()
                            }

                            Text(":")
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            Picker("Minutes", selection: $endMinuteIndex) {
                                ForEach(0..<quarterMinutes.count, id: \.self) { idx in
                                    Text(String(format: "%02d", quarterMinutes[idx])).tag(idx)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(width: 90, height: 120)
                            .clipped()
                            .onChange(of: endMinuteIndex) { _, _ in
                                rebuildEndDateFromPickers()
                                ensureMinAuctionEndDate()
                            }
                        }

                        // ✅ Résumé
                        HStack {
                            Text("Fin")
                            Spacer()
                            Text(endDate.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }

                        Text("Minimum: 8 heures. La fin ne pourra plus être modifiée après publication.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .onAppear {
                        // S’assure que les pickers reflètent endDate au moment où la section apparaît
                        alignPickersFromEndDate(roundUpToQuarter: true)
                        ensureMinAuctionEndDate()
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

    // MARK: - Presets

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

        // ✅ Important: synchroniser pickers ↔ endDate
        alignPickersFromEndDate(roundUpToQuarter: true)
        if type == .auction {
            ensureMinAuctionEndDate()
        }
    }

    // MARK: - Date helpers

    private func minAuctionEndDate() -> Date {
        Date().addingTimeInterval(minAuctionDurationSeconds)
    }

    /// Reconstruit endDate à partir de endDateOnly + endHour + quarterMinute
    private func rebuildEndDateFromPickers() {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: endDateOnly)
        comps.hour = endHour
        comps.minute = quarterMinutes[safe: endMinuteIndex] ?? 0
        comps.second = 0

        if let d = cal.date(from: comps) {
            endDate = d
        }
    }

    /// Aligne les pickers sur endDate (en arrondissant éventuellement au quart d’heure supérieur)
    private func alignPickersFromEndDate(roundUpToQuarter: Bool) {
        var d = endDate
        if roundUpToQuarter {
            d = roundDateUpToQuarterHour(d)
            endDate = d
        }

        let cal = Calendar.current
        endDateOnly = cal.startOfDay(for: d)
        endHour = cal.component(.hour, from: d)

        let m = cal.component(.minute, from: d)
        endMinuteIndex = nearestQuarterIndex(for: m, roundUp: roundUpToQuarter)
        // Rebuild pour forcer exactement 00/15/30/45 (ex: si minute = 17 -> 15 ou 30 selon roundUp)
        rebuildEndDateFromPickers()
    }

    private func ensureMinAuctionEndDate() {
        let minEnd = minAuctionEndDate()
        if endDate < minEnd {
            // On pousse à minEnd, puis on arrondit au prochain quart d’heure
            endDate = roundDateUpToQuarterHour(minEnd)
            alignPickersFromEndDate(roundUpToQuarter: true)
        }
    }

    private func nearestQuarterIndex(for minute: Int, roundUp: Bool) -> Int {
        // minute 0...59
        if roundUp {
            // 0-14 -> 0, 15-29 -> 15, 30-44 -> 30, 45-59 -> 45 (mais si >45, on montera l'heure via roundDateUpToQuarterHour)
            if minute <= 0 { return 0 }
            if minute <= 15 { return 1 }   // 15
            if minute <= 30 { return 2 }   // 30
            return 3                       // 45
        } else {
            // plus proche (rarement utilisé ici)
            let diffs = quarterMinutes.map { abs($0 - minute) }
            return diffs.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
        }
    }

    /// Arrondit une Date au prochain quart d’heure (00/15/30/45) en montant si nécessaire
    private func roundDateUpToQuarterHour(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = comps.minute ?? 0

        let remainder = minute % 15
        let add = remainder == 0 ? 0 : (15 - remainder)

        guard let base = cal.date(from: comps) else { return date }
        let rounded = cal.date(byAdding: .minute, value: add, to: base) ?? date

        // Force seconds = 0
        let finalComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: rounded)
        return cal.date(from: finalComps) ?? rounded
    }

    // MARK: - Submit

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

            // ✅ Force une dernière fois le respect du min + arrondi quart d’heure
            alignPickersFromEndDate(roundUpToQuarter: true)
            ensureMinAuctionEndDate()

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

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}

