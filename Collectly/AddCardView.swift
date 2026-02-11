import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// AddCardView
/// - Manual add screen used to create a CardItem in SwiftData.
/// - Safe defaults: images are optional, but we require at least one meaningful field before enabling Save.
struct AddCardView: View {

    // MARK: - Inputs

    let ownerId: String

    /// Optional callback (handy for analytics / UI updates).
    var onSaved: ((CardItem) -> Void)? = nil

    // MARK: - Environment

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // MARK: - Form state

    @State private var playerName: String = ""
    @State private var cardYear: String = ""
    @State private var companyName: String = ""
    @State private var setName: String = ""
    @State private var cardNumber: String = ""
    @State private var notes: String = ""

    // Grading
    @State private var isGraded: Bool = false
    @State private var gradingCompany: String = "PSA"
    @State private var gradeValue: String = ""
    @State private var certificationNumber: String = ""
    private let gradingCompanies = ["PSA", "BGS", "SGC", "CGC", "Autre"]

    // Images (optional)
    @State private var frontPickerItem: PhotosPickerItem? = nil
    @State private var backPickerItem: PhotosPickerItem? = nil
    @State private var frontImageData: Data? = nil
    @State private var backImageData: Data? = nil

    // UI state
    @State private var isSaving: Bool = false
    @State private var errorText: String? = nil
    @State private var showSavedToast: Bool = false

    // MARK: - Helpers

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var anyMeaningfulFieldFilled: Bool {
        !trimmed(playerName).isEmpty ||
        !trimmed(cardYear).isEmpty ||
        !trimmed(companyName).isEmpty ||
        !trimmed(setName).isEmpty ||
        !trimmed(cardNumber).isEmpty ||
        !trimmed(notes).isEmpty ||
        frontImageData != nil ||
        backImageData != nil
    }

    private var canSave: Bool {
        !trimmed(ownerId).isEmpty && anyMeaningfulFieldFilled && !isSaving
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom du joueur", text: $playerName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)

                    TextField("Année (ex: 2025-26)", text: $cardYear)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    TextField("Compagnie (Upper Deck, Topps…)", text: $companyName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)

                    TextField("Set (Series 1, SP Authentic…)", text: $setName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)

                    TextField("Numéro (ex: #207)", text: $cardNumber)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                } header: {
                    Text("Infos")
                }

                Section {
                    PhotosPicker(selection: $frontPickerItem, matching: .images) {
                        HStack {
                            Image(systemName: "photo")
                            Text(frontImageData == nil ? "Ajouter photo (recto)" : "Modifier photo (recto)")
                        }
                    }

                    PhotosPicker(selection: $backPickerItem, matching: .images) {
                        HStack {
                            Image(systemName: "photo")
                            Text(backImageData == nil ? "Ajouter photo (verso)" : "Modifier photo (verso)")
                        }
                    }

                    if frontImageData != nil || backImageData != nil {
                        HStack(spacing: 12) {
                            if let frontImageData, let ui = UIImage(data: frontImageData) {
                                Image(uiImage: ui)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 72)
                                    .clipped()
                                    .cornerRadius(10)
                            }
                            if let backImageData, let ui = UIImage(data: backImageData) {
                                Image(uiImage: ui)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 72)
                                    .clipped()
                                    .cornerRadius(10)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Photos")
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Notes")
                }

                Section {
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
                } header: {
                    Text("Grading")
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Ajouter une carte")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Enregistrer")
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                // Defensive: if ownerId is missing, show a clear message.
                if trimmed(ownerId).isEmpty {
                    errorText = "Impossible d'enregistrer: ownerId est vide. Assure-toi d'être connecté."
                }
            }
            .onChange(of: frontPickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    await loadPickerImageData(item: newItem, target: .front)
                }
            }
            .onChange(of: backPickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    await loadPickerImageData(item: newItem, target: .back)
                }
            }
            .alert("Copié", isPresented: $showSavedToast) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Carte enregistrée.")
            }
        }
    }

    // MARK: - Image loading

    private enum ImageTarget { case front, back }

    @MainActor
    private func loadPickerImageData(item: PhotosPickerItem, target: ImageTarget) async {
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                switch target {
                case .front: frontImageData = data
                case .back: backImageData = data
                }
            }
        } catch {
            errorText = "Impossible de charger l'image: \(error.localizedDescription)"
        }
    }

    // MARK: - Save

    @MainActor
    private func save() async {
        errorText = nil

        guard canSave else {
            if trimmed(ownerId).isEmpty {
                errorText = "Impossible d'enregistrer: ownerId est vide."
            } else if !anyMeaningfulFieldFilled {
                errorText = "Ajoute au moins une information (ou une photo) avant d'enregistrer."
            }
            return
        }

        isSaving = true
        defer { isSaving = false }

        let cleanPlayer = trimmed(playerName)
        let cleanYear = trimmed(cardYear)
        let cleanCompany = trimmed(companyName)
        let cleanSet = trimmed(setName)
        let cleanNumber = trimmed(cardNumber)
        let cleanNotes = trimmed(notes)
        let cleanGradeValue = trimmed(gradeValue)
        let cleanCertNumber = trimmed(certificationNumber)

        let title = !cleanPlayer.isEmpty ? cleanPlayer : "Nouvelle carte"

        let newItem = CardItem(
            ownerId: ownerId,
            title: title,
            notes: cleanNotes.isEmpty ? nil : cleanNotes,
            frontImageData: frontImageData,
            backImageData: backImageData,
            playerName: cleanPlayer.isEmpty ? nil : cleanPlayer,
            cardYear: cleanYear.isEmpty ? nil : cleanYear,
            companyName: cleanCompany.isEmpty ? nil : cleanCompany,
            setName: cleanSet.isEmpty ? nil : cleanSet,
            cardNumber: cleanNumber.isEmpty ? nil : cleanNumber
        )

        // Grading (must be set after init because CardItem initializer doesn't include these)
        newItem.isGraded = isGraded
        if isGraded {
            newItem.gradingCompany = gradingCompany.isEmpty ? nil : gradingCompany
            newItem.gradeValue = cleanGradeValue.isEmpty ? nil : cleanGradeValue
            newItem.certificationNumber = cleanCertNumber.isEmpty ? nil : cleanCertNumber
        } else {
            newItem.gradingCompany = nil
            newItem.gradeValue = nil
            newItem.certificationNumber = nil
        }

        // Insert + save
        modelContext.insert(newItem)

        do {
            try modelContext.save()

            // Debug help: if you still "see nothing", it usually means the query predicate doesn't match.
            print("✅ AddCardView saved CardItem id=\(newItem.id) ownerId=\(newItem.ownerId) title=\(newItem.title)")

            onSaved?(newItem)
            showSavedToast = true

            // Close the sheet after a short tick so the alert can appear if you want.
            // If you prefer immediate dismiss, comment the next two lines and call dismiss() directly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                dismiss()
            }
        } catch {
            // If save fails, keep the sheet open and show the error.
            errorText = "Erreur lors de l'enregistrement: \(error.localizedDescription)"
            print("❌ AddCardView save error: \(error)")
        }
    }
}
