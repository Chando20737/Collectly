import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct EditCardView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Bindable var card: CardItem

    // ✅ Optional: open editor directly on a specific section (for "Compléter")
    enum InitialSection: String {
        case base
        case photo
        case fiche
        case grading
        case badges
    }

    private let initialSection: InitialSection?

    // Base
    @State private var title: String = ""
    @State private var notes: String = ""
    
    // ✅ Quantité et valeur
    @State private var quantity: Int = 1
    @State private var priceText: String = ""

    // Photo
    @State private var selectedItem: PhotosPickerItem?
    @State private var imageData: Data?

    // Fiche
    @State private var playerName: String = ""
    @State private var cardYear: String = ""
    @State private var companyName: String = ""
    @State private var setName: String = ""
    @State private var cardNumber: String = ""

    // Grading
    @State private var isGraded: Bool = false
    @State private var gradingCompany: String = "PSA"
    @State private var gradeValue: String = ""
    @State private var certificationNumber: String = ""
    private let gradingCompanies = ["PSA", "BGS", "SGC", "CGC", "Autre"]

    // Badges
    @State private var badgeMode: CardBadgeMode = .mix
    @State private var manualBadges: Set<CardBadge> = []
    @State private var disabledBadges: Set<CardBadge> = []

    // UI
    @State private var isSaving = false
    @State private var errorText: String?

    init(card: CardItem, initialSection: InitialSection? = nil) {
        self._card = Bindable(wrappedValue: card)
        self.initialSection = initialSection
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {

                    // ✅ PHOTO
                    Section("Photo") {
                        VStack(spacing: 12) {
                            CardImagePickerPreview(data: imageData)

                            PhotosPicker(selection: $selectedItem, matching: .images) {
                                Label(imageData == nil ? "Choisir une image" : "Changer l’image",
                                      systemImage: "photo.on.rectangle")
                            }

                            if imageData != nil {
                                Button(role: .destructive) {
                                    selectedItem = nil
                                    imageData = nil
                                } label: {
                                    Label("Retirer l’image", systemImage: "trash")
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .id("section.photo")

                    // ✅ BASE
                    Section("Base") {
                        TextField("Titre", text: $title)
                            .textInputAutocapitalization(.sentences)
                            .autocorrectionDisabled(true)

                        ZStack(alignment: .topLeading) {
                            if notes.trimmed.isEmpty {
                                Text("Notes (optionnel)")
                                    .foregroundStyle(.secondary.opacity(0.7))
                                    .padding(.top, 8)
                                    .padding(.leading, 6)
                            }

                            TextEditor(text: $notes)
                                .frame(minHeight: 90)
                                .padding(.horizontal, 2)
                                .textInputAutocapitalization(.sentences)
                                .autocorrectionDisabled(true)
                        }
                    }
                    .id("section.base")

                    // ✅ FICHE
                    Section("Fiche de la carte") {
                        TextField("Nom du joueur", text: $playerName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled(true)

                        TextField("Année (ex: 2023-24)", text: $cardYear)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.asciiCapable)

                        TextField("Compagnie (Upper Deck, Topps…)", text: $companyName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled(true)

                        TextField("Set (Series 1, SP Authentic…)", text: $setName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled(true)

                        TextField("Numéro (#201)", text: $cardNumber)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.asciiCapable)
                    }
                    .id("section.fiche")

                    // ✅ GRADING
                    Section("Grading") {
                        Toggle("Carte gradée", isOn: $isGraded)

                        if isGraded {
                            Picker("Compagnie", selection: $gradingCompany) {
                                ForEach(gradingCompanies, id: \.self) { c in
                                    Text(c).tag(c)
                                }
                            }

                            TextField("Note (ex: 10, 9.5)", text: $gradeValue)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)

                            TextField("Certification #", text: $certificationNumber)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .keyboardType(.asciiCapable)
                        } else {
                            Text("Ajoute les infos de grading si la carte est encapsulée (PSA, BGS, SGC…).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .id("section.grading")
                    .onChange(of: isGraded) { _, newValue in
                        if !newValue {
                            gradeValue = ""
                            certificationNumber = ""
                        }
                    }

                    // ✅ BADGES
                    Section("Badges") {
                        Picker("Mode", selection: $badgeMode) {
                            ForEach(CardBadgeMode.allCases) { m in
                                Text(m.label).tag(m)
                            }
                        }

                        // Auto-detected badges preview
                        let auto = CardBadgesEngine.autoBadges(
                            title: title.trimmed,
                            notes: notes.trimmed.isEmpty ? nil : notes.trimmed,
                            setName: setName.trimmed.nonEmptyOrNil,
                            companyName: companyName.trimmed.nonEmptyOrNil,
                            cardNumber: cardNumber.trimmed.nonEmptyOrNil,
                            isGraded: isGraded
                        )

                        ForEach(CardBadge.allCases) { b in
                            Toggle(isOn: Binding(
                                get: {
                                    switch badgeMode {
                                    case .manual:
                                        return manualBadges.contains(b)
                                    case .auto, .mix:
                                        return (auto.contains(b) || manualBadges.contains(b)) && !disabledBadges.contains(b)
                                    }
                                },
                                set: { on in
                                    switch badgeMode {
                                    case .manual:
                                        if on { manualBadges.insert(b) } else { manualBadges.remove(b) }
                                    case .auto, .mix:
                                        if on {
                                            disabledBadges.remove(b)
                                            if !auto.contains(b) { manualBadges.insert(b) }
                                        } else {
                                            disabledBadges.insert(b)
                                            manualBadges.remove(b)
                                        }
                                    }
                                }
                            )) {
                                HStack(spacing: 8) {
                                    Label(b.label, systemImage: b.systemImage)
                                    Spacer()
                                    if (badgeMode == .auto || badgeMode == .mix), auto.contains(b) {
                                        Text("Auto")
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(.thinMaterial)
                                            .clipShape(Capsule())
                                    }
                                    if (badgeMode == .auto || badgeMode == .mix), disabledBadges.contains(b) {
                                        Text("Masqué")
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(.thinMaterial)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }

                        if badgeMode == .manual {
                            Text("Mode « Manuel »: tu contrôles 100% des badges. Les détections automatiques sont ignorées.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Astuce: si un badge apparaît automatiquement (ex: Patch), tu peux le désactiver ici (il sera « masqué »).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .id("section.badges")
                    
                    // ✅ Quantité
                    Section("Quantité") {
                        Stepper(value: $quantity, in: 1...999) {
                            HStack {
                                Text("Nombre d'exemplaires")
                                Spacer()
                                Text("x\(quantity)")
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    // ✅ Valeur estimée
                    Section("Valeur estimée (CAD)") {
                        TextField("ex: 25.00", text: $priceText)
                            .keyboardType(.decimalPad)
                    }

                    if let errorText {
                        Section("Erreur") {
                            Text(errorText).foregroundStyle(.red)
                        }
                    }
                }
                .navigationTitle("Modifier")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Annuler") { dismiss() }
                            .disabled(isSaving)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(isSaving ? "Enregistrement..." : "Enregistrer") {
                            save()
                        }
                        .disabled(!canSave)
                    }
                }
                .onAppear {
                    loadFromCard()
                    if let initialSection {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.easeInOut) {
                                proxy.scrollTo("section.\(initialSection.rawValue)", anchor: .top)
                            }
                        }
                    }
                }
                .onChange(of: selectedItem) { _, newItem in
                    guard let newItem else { return }
                    loadImage(from: newItem)
                }
            }
        }
    }

    private var canSave: Bool {
        if isSaving { return false }
        return !title.trimmed.isEmpty
    }

    private func loadFromCard() {
        title = card.title
        notes = card.notes ?? ""

        imageData = card.frontImageData

        playerName = card.playerName ?? ""
        cardYear = card.cardYear ?? ""
        companyName = card.companyName ?? ""
        setName = card.setName ?? ""
        cardNumber = card.cardNumber ?? ""

        isGraded = (card.isGraded == true)
        gradingCompany = card.gradingCompany ?? "PSA"
        gradeValue = card.gradeValue ?? ""
        certificationNumber = card.certificationNumber ?? ""

        // Badges
        badgeMode = CardBadgeMode(rawValue: (card.badgeModeRaw ?? "mix").lowercased()) ?? .mix
        manualBadges = CardBadgesEngine.parseManualBadges(card.manualBadgesRaw)
        disabledBadges = CardBadgesEngine.parseManualBadges(card.disabledBadgesRaw)
        
        // ✅ Quantité (depuis UserDefaults)
        quantity = QuantityStore.quantity(id: card.id)
        
        // ✅ Prix
        priceText = card.estimatedPriceCAD.map { String(format: "%.2f", $0) } ?? ""
    }

    private func loadImage(from item: PhotosPickerItem) {
        errorText = nil
        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let finalData = compressIfNeeded(data)
                    await MainActor.run { self.imageData = finalData }
                }
            } catch {
                await MainActor.run { self.errorText = error.localizedDescription }
            }
        }
    }

    private func compressIfNeeded(_ data: Data) -> Data {
        guard let ui = UIImage(data: data) else { return data }
        return ui.jpegData(compressionQuality: 0.85) ?? data
    }

    private func save() {
        errorText = nil
        isSaving = true

        // Base
        let t = title.trimmed
        if t.isEmpty {
            errorText = "Le titre est obligatoire."
            isSaving = false
            return
        }

        card.title = t
        card.notes = notes.trimmed.isEmpty ? nil : notes.trimmed

        // Photo
        card.frontImageData = imageData

        // Fiche
        card.playerName = playerName.trimmed.nonEmptyOrNil
        card.cardYear = cardYear.trimmed.nonEmptyOrNil
        card.companyName = companyName.trimmed.nonEmptyOrNil
        card.setName = setName.trimmed.nonEmptyOrNil
        card.cardNumber = cardNumber.trimmed.nonEmptyOrNil

        // Grading
        card.isGraded = isGraded
        if isGraded {
            card.gradingCompany = gradingCompany.trimmed.nonEmptyOrNil
            card.gradeValue = gradeValue.trimmed.nonEmptyOrNil
            card.certificationNumber = certificationNumber.trimmed.nonEmptyOrNil
        } else {
            card.gradingCompany = nil
            card.gradeValue = nil
            card.certificationNumber = nil
        }

        // Badges
        card.badgeModeRaw = badgeMode.rawValue
        card.manualBadgesRaw = CardBadgesEngine.encodeManualBadges(manualBadges)
        card.disabledBadgesRaw = CardBadgesEngine.encodeManualBadges(disabledBadges)
        
        // ✅ Quantité (UserDefaults)
        QuantityStore.setQuantity(quantity, id: card.id)
        
        // ✅ Valeur estimée
        let cleaned = priceText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let v = Double(cleaned), v > 0 {
            card.estimatedPriceCAD = (v * 100).rounded() / 100
        } else {
            card.estimatedPriceCAD = nil
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorText = error.localizedDescription
            isSaving = false
        }
    }
}

private struct CardImagePickerPreview: View {
    let data: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))

            if let data, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(10)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Aucune image sélectionnée")
                        .foregroundStyle(.secondary)
                }
            }

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 1)
        }
        .frame(height: 240)
    }
}
