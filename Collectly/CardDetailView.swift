//
//  CardDetailView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import SwiftData
import UIKit
import FirebaseAuth
import FirebaseFirestore

struct CardDetailView: View {
    @Bindable var card: CardItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // Firestore listing state (si connecté)
    @State private var listing: CardDetailListingMini? = nil
    @State private var listingListener: ListenerRegistration? = nil
    @State private var listingError: String? = nil

    // Sheets
    @State private var showSellSheet = false
    @State private var showEditSheet = false

    // ✅ Valeur estimée (édition)
    @State private var priceText: String = ""
    @State private var isSavingPrice = false

    // UI
    @State private var uiErrorText: String? = nil
    @State private var isWorking = false

    // ✅ Patch UI: pause/publish
    @State private var isUpdatingStatus = false

    private let marketplace = MarketplaceService()
    private let db = Firestore.firestore()

    var body: some View {
        Form {

            // ✅ IMAGE EN PREMIER
            Section {
                CardHeroImage(data: card.frontImageData)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            // ✅ INFOS (titre + notes)
            Section {
                Text(card.title)
                    .font(.headline)

                if let notes = card.notes, !notes.trimmedLocal.isEmpty {
                    Text(notes)
                        .foregroundStyle(.secondary)
                }
            }

            // ✅ FICHE DE LA CARTE
            Section("Fiche de la carte") {
                LabeledContent("Joueur") { Text(card.playerName.cleanOrDash).foregroundStyle(.secondary) }
                LabeledContent("Année") { Text(card.cardYear.cleanOrDash).foregroundStyle(.secondary) }
                LabeledContent("Compagnie") { Text(card.companyName.cleanOrDash).foregroundStyle(.secondary) }
                LabeledContent("Set") { Text(card.setName.cleanOrDash).foregroundStyle(.secondary) }
                LabeledContent("Numéro") { Text(card.cardNumber.cleanOrDash).foregroundStyle(.secondary) }
            }

            // ✅ GRADING
            Section("Grading") {
                LabeledContent("Gradée") {
                    Text((card.isGraded == true) ? "Oui" : "Non")
                        .foregroundStyle(.secondary)
                }

                if card.isGraded == true {
                    LabeledContent("Compagnie") { Text(card.gradingCompany.cleanOrDash).foregroundStyle(.secondary) }
                    LabeledContent("Note") { Text(card.gradeValue.cleanOrDash).foregroundStyle(.secondary) }
                    LabeledContent("Certification") { Text(card.certificationNumber.cleanOrDash).foregroundStyle(.secondary) }
                } else {
                    Text("Ajoute les infos de grading si la carte est encapsulée (PSA, BGS, SGC…).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // ✅ ACQUISITION
            Section("Acquisition") {
                LabeledContent("Date d’acquisition") {
                    Text(acquisitionDateText).foregroundStyle(.secondary)
                }
                LabeledContent("Source") {
                    Text(card.acquisitionSource.cleanOrDash).foregroundStyle(.secondary)
                }
                LabeledContent("Prix payé") {
                    Text(purchasePriceText).foregroundStyle(.secondary)
                }
            }

            // ✅ VALEUR ESTIMÉE (avec décimales)
            Section("Valeur estimée") {
                HStack {
                    TextField("Ex: 4.50", text: $priceText)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    Text("$ CAD")
                        .foregroundStyle(.secondary)
                }

                if let current = card.estimatedPriceCAD {
                    Text(String(format: "Actuel : ≈ %.2f $ CAD", current))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Aucune valeur estimée pour le moment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button(isSavingPrice ? "Enregistrement..." : "Enregistrer") {
                    saveEstimatedPrice()
                }
                .disabled(isSavingPrice)
            }

            // ✅ ÉTAT FIRESTORE
            Section("Annonce") {
                if Auth.auth().currentUser == nil {
                    Text("Connecte-toi pour mettre en vente.")
                        .foregroundStyle(.secondary)
                } else if let listing {
                    HStack {
                        Text("Statut")
                        Spacer()
                        Text(listing.statusLabel)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Type")
                        Spacer()
                        Text(listing.typeLabel)
                            .foregroundStyle(.secondary)
                    }

                    if listing.type == "fixedPrice", let p = listing.buyNowPriceCAD {
                        HStack {
                            Text("Prix")
                            Spacer()
                            Text(String(format: "%.2f $ CAD", p))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if listing.type == "auction" {
                        let current = listing.currentBidCAD ?? listing.startingBidCAD ?? 0
                        Text(String(format: "Mise: %.2f $ CAD • %@", current, miseText(listing.bidCount)))
                            .foregroundStyle(.secondary)

                        if let end = listing.endDate {
                            Text("Se termine le \(end.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Aucune annonce associée à cette carte.")
                        .foregroundStyle(.secondary)
                }

                if let listingError, !listingError.isEmpty {
                    Text("⚠️ \(listingError)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // ✅ ACTIONS
            Section("Actions") {

                Button {
                    showEditSheet = true
                } label: {
                    Label("Modifier", systemImage: "pencil")
                }
                .disabled(isWorking || isUpdatingStatus)

                Button {
                    showSellSheet = true
                } label: {
                    Label(sellButtonTitle, systemImage: "tag")
                }
                .disabled(Auth.auth().currentUser == nil || isWorking || isUpdatingStatus)

                // ✅ PATCH UI: Pause / Publish pour prix fixe
                if let listing,
                   listing.type == "fixedPrice",
                   (listing.status == "active" || listing.status == "paused") {

                    if listing.status == "active" {
                        Button {
                            Task { await updateListingStatus(newStatus: "paused") }
                        } label: {
                            Label(isUpdatingStatus ? "Mise en pause..." : "Mettre en pause", systemImage: "pause.circle")
                        }
                        .disabled(isWorking || isUpdatingStatus)
                    } else if listing.status == "paused" {
                        Button {
                            Task { await updateListingStatus(newStatus: "active") }
                        } label: {
                            Label(isUpdatingStatus ? "Publication..." : "Publier dans Marketplace", systemImage: "paperplane.circle")
                        }
                        .disabled(isWorking || isUpdatingStatus)
                    }
                }

                if canEndListing {
                    Button(role: .destructive) {
                        Task { await endListingNow() }
                    } label: {
                        Label("Retirer l’annonce", systemImage: "xmark.circle")
                    }
                    .disabled(isWorking || isUpdatingStatus)
                }
            }

            // ✅ SUPPRIMER LA CARTE (local)
            Section {
                Button(role: .destructive) {
                    Task { await deleteCardLocallyAndEndListingIfNeeded() }
                } label: {
                    Label("Supprimer la carte", systemImage: "trash")
                }
                .disabled(isWorking || isUpdatingStatus)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Modifier") { showEditSheet = true }
                    .disabled(isWorking || isUpdatingStatus)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Fermer") { dismiss() }
                    .disabled(isWorking || isUpdatingStatus)
            }
        }
        .onAppear {
            if let p = card.estimatedPriceCAD {
                priceText = String(format: "%.2f", p)
            } else {
                priceText = ""
            }
            startListingListenerIfNeeded()
        }
        .onDisappear { stopListingListener() }

        .sheet(isPresented: $showSellSheet) {
            CardDetailSellCardSheetView(card: card, existing: listing) { title, desc, type, buyNow, startBid, endDate in
                Task {
                    await createListing(
                        title: title,
                        description: desc,
                        type: type,
                        buyNow: buyNow,
                        startBid: startBid,
                        endDate: endDate
                    )
                }
            }
        }

        .sheet(isPresented: $showEditSheet) {
            EditCardDetailsSheetView(card: card)
        }

        .alert("Erreur", isPresented: Binding(
            get: { uiErrorText != nil },
            set: { if !$0 { uiErrorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(uiErrorText ?? "")
        }
    }

    // MARK: - Derived texts

    private var acquisitionDateText: String {
        guard let d = card.acquisitionDate else { return "—" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    private var purchasePriceText: String {
        guard let p = card.purchasePriceCAD else { return "—" }
        return String(format: "%.2f $ CAD", p)
    }

    // MARK: - French pluralization

    private func miseText(_ count: Int) -> String {
        return count <= 1 ? "\(count) mise" : "\(count) mises"
    }

    // MARK: - Valeur estimée

    private func saveEstimatedPrice() {
        uiErrorText = nil
        isSavingPrice = true

        let t = priceText.trimmedLocal
        if t.isEmpty {
            card.estimatedPriceCAD = nil
            do {
                try modelContext.save()
                isSavingPrice = false
                return
            } catch {
                uiErrorText = error.localizedDescription
                isSavingPrice = false
                return
            }
        }

        let normalized = t.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(normalized), v >= 0 else {
            uiErrorText = "Entre un montant valide (ex: 4.50)."
            isSavingPrice = false
            return
        }

        let rounded = (v * 100).rounded() / 100
        card.estimatedPriceCAD = rounded

        do {
            try modelContext.save()
            isSavingPrice = false
        } catch {
            uiErrorText = error.localizedDescription
            isSavingPrice = false
        }
    }

    // MARK: - UI derived

    private var sellButtonTitle: String {
        guard Auth.auth().currentUser != nil else { return "Mettre en vente" }
        guard let listing else { return "Mettre en vente" }

        if listing.status == "ended" || listing.status == "sold" {
            return "Remettre en vente"
        }
        return "Modifier la vente"
    }

    private var canEndListing: Bool {
        guard Auth.auth().currentUser != nil else { return false }
        guard let listing else { return false }
        if listing.status == "ended" || listing.status == "sold" { return false }

        if listing.type == "fixedPrice" {
            return listing.status == "active" || listing.status == "paused"
        }
        if listing.type == "auction" {
            return listing.status == "active" && listing.bidCount == 0
        }
        return false
    }

    // MARK: - Firestore listener (sans orderBy, pas d’index requis)

    private func startListingListenerIfNeeded() {
        stopListingListener()
        listingError = nil
        listing = nil

        guard let uid = Auth.auth().currentUser?.uid else { return }
        let cardItemId = card.id.uuidString

        listingListener = db.collection("listings")
            .whereField("sellerId", isEqualTo: uid)
            .whereField("cardItemId", isEqualTo: cardItemId)
            .limit(to: 10)
            .addSnapshotListener { snap, error in

                if let ns = error as NSError? {
                    if ns.domain == "FIRFirestoreErrorDomain" && ns.code == 7 {
                        self.listingError = nil
                        self.listing = nil
                        return
                    }

                    let msg = ns.localizedDescription
                    if msg.lowercased().contains("requires an index") {
                        self.listingError = nil
                        self.listing = nil
                        return
                    }

                    self.listingError = msg
                    self.listing = nil
                    return
                }

                guard let snap else { return }

                if snap.documents.isEmpty {
                    self.listing = nil
                    self.listingError = nil
                    return
                }

                let best = snap.documents.max { a, b in
                    let ta = (a.data()["createdAt"] as? Timestamp)?.dateValue() ?? .distantPast
                    let tb = (b.data()["createdAt"] as? Timestamp)?.dateValue() ?? .distantPast
                    return ta < tb
                }

                if let best {
                    self.listing = CardDetailListingMini.fromFirestore(doc: best)
                } else {
                    self.listing = CardDetailListingMini.fromFirestore(doc: snap.documents[0])
                }
                self.listingError = nil
            }
    }

    private func stopListingListener() {
        listingListener?.remove()
        listingListener = nil
    }

    // MARK: - Actions

    private func createListing(
        title: String,
        description: String?,
        type: ListingType,
        buyNow: Double?,
        startBid: Double?,
        endDate: Date?
    ) async {
        uiErrorText = nil
        isWorking = true
        defer { isWorking = false }

        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDesc = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let desc: String? = finalDesc.isEmpty ? nil : finalDesc

        if finalTitle.isEmpty {
            uiErrorText = "Le titre est obligatoire."
            return
        }

        if type == .fixedPrice {
            guard let p = buyNow, p > 0 else {
                uiErrorText = "Entre un prix valide."
                return
            }
        } else {
            guard let s = startBid, s >= 0 else {
                uiErrorText = "Entre une mise de départ valide."
                return
            }
            guard let end = endDate else {
                uiErrorText = "La date de fin est obligatoire."
                return
            }

            let minAuctionSeconds: TimeInterval = (8 * 60 * 60) + 120
            let minEnd = Date().addingTimeInterval(minAuctionSeconds)
            if end < minEnd {
                uiErrorText = "Un encan doit durer au moins 8 heures."
                return
            }
        }

        do {
            try await marketplace.createListingFromCollection(
                from: card,
                title: finalTitle,
                description: desc,
                type: type,
                buyNowPriceCAD: (type == .fixedPrice ? buyNow : nil),
                startingBidCAD: (type == .auction ? startBid : nil),
                endDate: (type == .auction ? endDate : nil)
            )
        } catch {
            uiErrorText = error.localizedDescription
        }
    }

    private func endListingNow() async {
        uiErrorText = nil
        isWorking = true
        defer { isWorking = false }

        guard let listing else { return }

        do {
            try await marketplace.endListing(listingId: listing.id)
        } catch {
            uiErrorText = error.localizedDescription
        }
    }

    private func updateListingStatus(newStatus: String) async {
        uiErrorText = nil
        isUpdatingStatus = true
        defer { isUpdatingStatus = false }

        guard Auth.auth().currentUser != nil else {
            uiErrorText = MarketplaceError.notSignedIn.localizedDescription
            return
        }
        guard let listing else { return }

        do {
            try await db.collection("listings").document(listing.id).updateData([
                "status": newStatus,
                "updatedAt": Timestamp(date: Date())
            ])
        } catch {
            uiErrorText = error.localizedDescription
        }
    }

    // ✅ FIX: Une seule fonction (plus de redeclaration)
    private func deleteCardLocallyAndEndListingIfNeeded() async {
        uiErrorText = nil
        isWorking = true
        defer { isWorking = false }

        await marketplace.endListingIfExistsForDeletedCard(cardItemId: card.id.uuidString)

        await MainActor.run {
            modelContext.delete(card)
            do {
                try modelContext.save()
                dismiss()
            } catch {
                uiErrorText = error.localizedDescription
            }
        }
    }
}

// MARK: - ✅ Sheet: vendre / modifier la vente

private struct CardDetailSellCardSheetView: View {
    let card: CardItem
    let existing: CardDetailListingMini?
    let onSubmit: (_ title: String, _ description: String?, _ type: ListingType, _ buyNow: Double?, _ startBid: Double?, _ endDate: Date?) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum SellType: String, CaseIterable, Identifiable {
        case fixedPrice
        case auction
        var id: String { rawValue }

        var label: String {
            switch self {
            case .fixedPrice: return "Prix fixe"
            case .auction: return "Encan"
            }
        }
    }

    @State private var title: String = ""
    @State private var descriptionText: String = ""

    @State private var sellType: SellType = .fixedPrice

    @State private var buyNowText: String = ""
    @State private var startBidText: String = ""
    @State private var endDate: Date = Date().addingTimeInterval((8 * 60 * 60) + 180)

    @State private var uiError: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Annonce") {
                    TextField("Titre", text: $title)
                        .textInputAutocapitalization(.sentences)

                    TextField("Description (optionnel)", text: $descriptionText, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Type") {
                    Picker("Type", selection: $sellType) {
                        ForEach(SellType.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if sellType == .fixedPrice {
                    Section("Prix fixe") {
                        TextField("Prix (ex: 25.00)", text: $buyNowText)
                            .keyboardType(.decimalPad)
                        Text("$ CAD")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Encan") {
                        TextField("Mise de départ (ex: 0.00)", text: $startBidText)
                            .keyboardType(.decimalPad)
                        DatePicker("Fin", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                    }
                }

                if let uiError, !uiError.isEmpty {
                    Section {
                        Text("⚠️ \(uiError)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Mettre en vente" : "Modifier la vente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Enregistrer") { submit() }
                }
            }
            .onAppear {
                title = card.title

                if let existing {
                    if existing.type == "auction" {
                        sellType = .auction
                        if let s = existing.startingBidCAD { startBidText = String(format: "%.2f", s) }
                        if let e = existing.endDate { endDate = e }
                    } else {
                        sellType = .fixedPrice
                        if let p = existing.buyNowPriceCAD { buyNowText = String(format: "%.2f", p) }
                    }
                }
            }
        }
    }

    private func submit() {
        uiError = nil

        let finalTitle = title.trimmedLocal
        if finalTitle.isEmpty {
            uiError = "Le titre est obligatoire."
            return
        }

        let finalDesc = descriptionText.trimmedLocal
        let desc: String? = finalDesc.isEmpty ? nil : finalDesc

        switch sellType {
        case .fixedPrice:
            let normalized = buyNowText.trimmedLocal.replacingOccurrences(of: ",", with: ".")
            guard let p = Double(normalized), p > 0 else {
                uiError = "Entre un prix valide (ex: 25.00)."
                return
            }
            onSubmit(finalTitle, desc, .fixedPrice, p, nil, nil)
            dismiss()

        case .auction:
            let normalized = startBidText.trimmedLocal.replacingOccurrences(of: ",", with: ".")
            guard let s = Double(normalized), s >= 0 else {
                uiError = "Entre une mise de départ valide (ex: 0.00)."
                return
            }
            onSubmit(finalTitle, desc, .auction, nil, s, endDate)
            dismiss()
        }
    }
}

// MARK: - ✅ Sheet: modifier la carte

private struct EditCardDetailsSheetView: View {
    @Bindable var card: CardItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var title: String = ""
    @State private var notes: String = ""

    @State private var playerName: String = ""
    @State private var cardYear: String = ""
    @State private var companyName: String = ""
    @State private var setName: String = ""
    @State private var cardNumber: String = ""

    @State private var isGraded: Bool = false
    @State private var gradingCompany: String = ""
    @State private var gradeValue: String = ""
    @State private var certificationNumber: String = ""

    @State private var acquisitionSource: String = ""
    @State private var acquisitionDate: Date = Date()
    @State private var hasAcquisitionDate: Bool = false

    @State private var purchasePriceText: String = ""

    @State private var uiError: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Base") {
                    TextField("Titre", text: $title)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section("Fiche de la carte") {
                    TextField("Joueur", text: $playerName)
                    TextField("Année", text: $cardYear)
                    TextField("Compagnie", text: $companyName)
                    TextField("Set", text: $setName)
                    TextField("Numéro", text: $cardNumber)
                }

                Section("Grading") {
                    Toggle("Carte gradée", isOn: $isGraded)

                    if isGraded {
                        TextField("Compagnie (PSA/BGS/SGC)", text: $gradingCompany)
                        TextField("Note (ex: 10)", text: $gradeValue)
                        TextField("Certification (optionnel)", text: $certificationNumber)
                    }
                }

                Section("Acquisition") {
                    Toggle("Date d’acquisition", isOn: $hasAcquisitionDate)
                    if hasAcquisitionDate {
                        DatePicker("Date", selection: $acquisitionDate, displayedComponents: .date)
                    }

                    TextField("Source", text: $acquisitionSource)

                    TextField("Prix payé (optionnel)", text: $purchasePriceText)
                        .keyboardType(.decimalPad)

                    Text("$ CAD")
                        .foregroundStyle(.secondary)
                }

                if let uiError, !uiError.isEmpty {
                    Section {
                        Text("⚠️ \(uiError)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Modifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Enregistrer") { save() }
                }
            }
            .onAppear {
                title = card.title
                notes = card.notes ?? ""

                playerName = card.playerName ?? ""
                cardYear = card.cardYear ?? ""
                companyName = card.companyName ?? ""
                setName = card.setName ?? ""
                cardNumber = card.cardNumber ?? ""

                isGraded = (card.isGraded == true)
                gradingCompany = card.gradingCompany ?? ""
                gradeValue = card.gradeValue ?? ""
                certificationNumber = card.certificationNumber ?? ""

                acquisitionSource = card.acquisitionSource ?? ""
                if let d = card.acquisitionDate {
                    acquisitionDate = d
                    hasAcquisitionDate = true
                } else {
                    hasAcquisitionDate = false
                }

                if let p = card.purchasePriceCAD {
                    purchasePriceText = String(format: "%.2f", p)
                } else {
                    purchasePriceText = ""
                }
            }
        }
    }

    private func save() {
        uiError = nil

        let finalTitle = title.trimmedLocal
        if finalTitle.isEmpty {
            uiError = "Le titre est obligatoire."
            return
        }

        card.title = finalTitle
        card.notes = notes.trimmedLocal.isEmpty ? nil : notes.trimmedLocal

        card.playerName = playerName.trimmedLocal.isEmpty ? nil : playerName.trimmedLocal
        card.cardYear = cardYear.trimmedLocal.isEmpty ? nil : cardYear.trimmedLocal
        card.companyName = companyName.trimmedLocal.isEmpty ? nil : companyName.trimmedLocal
        card.setName = setName.trimmedLocal.isEmpty ? nil : setName.trimmedLocal
        card.cardNumber = cardNumber.trimmedLocal.isEmpty ? nil : cardNumber.trimmedLocal

        card.isGraded = isGraded
        if isGraded {
            card.gradingCompany = gradingCompany.trimmedLocal.isEmpty ? nil : gradingCompany.trimmedLocal
            card.gradeValue = gradeValue.trimmedLocal.isEmpty ? nil : gradeValue.trimmedLocal
            card.certificationNumber = certificationNumber.trimmedLocal.isEmpty ? nil : certificationNumber.trimmedLocal
        } else {
            card.gradingCompany = nil
            card.gradeValue = nil
            card.certificationNumber = nil
        }

        card.acquisitionSource = acquisitionSource.trimmedLocal.isEmpty ? nil : acquisitionSource.trimmedLocal
        card.acquisitionDate = hasAcquisitionDate ? acquisitionDate : nil

        let pp = purchasePriceText.trimmedLocal.replacingOccurrences(of: ",", with: ".")
        if pp.isEmpty {
            card.purchasePriceCAD = nil
        } else if let v = Double(pp), v >= 0 {
            card.purchasePriceCAD = (v * 100).rounded() / 100
        } else {
            uiError = "Prix payé invalide (ex: 12.50)."
            return
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            uiError = error.localizedDescription
        }
    }
}

// MARK: - Image locale

private struct CardHeroImage: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.secondary.opacity(0.12))

                    VStack(spacing: 10) {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)

                        Text("Aucune image")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 220)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Mini listing model

private struct CardDetailListingMini: Identifiable {
    let id: String
    let type: String
    let status: String
    let buyNowPriceCAD: Double?
    let startingBidCAD: Double?
    let currentBidCAD: Double?
    let bidCount: Int
    let endDate: Date?

    var typeLabel: String { type == "fixedPrice" ? "Prix fixe" : "Encan" }

    var statusLabel: String {
        switch status {
        case "active": return "Active"
        case "paused": return "En pause"
        case "sold": return "Vendue"
        case "ended": return "Terminée"
        default: return status
        }
    }

    static func fromFirestore(doc: DocumentSnapshot) -> CardDetailListingMini {
        let data = doc.data() ?? [:]

        func readInt(_ any: Any?) -> Int {
            if let i = any as? Int { return i }
            if let i64 = any as? Int64 { return Int(i64) }
            if let n = any as? NSNumber { return n.intValue }
            if let d = any as? Double { return Int(d) }
            return 0
        }

        func readDouble(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
            if let i64 = any as? Int64 { return Double(i64) }
            if let n = any as? NSNumber { return n.doubleValue }
            return nil
        }

        func date(_ key: String) -> Date? { (data[key] as? Timestamp)?.dateValue() }

        return CardDetailListingMini(
            id: doc.documentID,
            type: (data["type"] as? String) ?? "fixedPrice",
            status: (data["status"] as? String) ?? "active",
            buyNowPriceCAD: readDouble(data["buyNowPriceCAD"]),
            startingBidCAD: readDouble(data["startingBidCAD"]),
            currentBidCAD: readDouble(data["currentBidCAD"]),
            bidCount: readInt(data["bidCount"]),
            endDate: date("endDate")
        )
    }
}

// MARK: - Helpers (fichier local)

private extension String {
    var trimmedLocal: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension Optional where Wrapped == String {
    var cleanOrDash: String {
        guard let v = self?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return "—" }
        return v
    }
}
