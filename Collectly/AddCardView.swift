//
//  AddCardView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct AddCardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // ✅ IMPORTANT: ownerId obligatoire (Firebase uid)
    let ownerId: String

    // Infos de base
    @State private var title: String = ""
    @State private var notes: String = ""

    // Image
    @State private var selectedItem: PhotosPickerItem?
    @State private var imageData: Data?

    // ✅ Fiche
    @State private var playerName: String = ""
    @State private var cardYear: String = ""
    @State private var companyName: String = ""
    @State private var setName: String = ""
    @State private var cardNumber: String = ""

    // ✅ Grading
    @State private var isGraded: Bool = false
    @State private var gradingCompany: String = "PSA"
    @State private var gradeValue: String = ""
    @State private var certificationNumber: String = ""
    private let gradingCompanies = ["PSA", "BGS", "SGC", "CGC", "Autre"]

    // UI
    @State private var isSaving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    VStack(spacing: 12) {
                        CardImagePickerPreview(data: imageData)

                        PhotosPicker(selection: $selectedItem, matching: .images) {
                            Label(imageData == nil ? "Choisir une image" : "Changer l’image", systemImage: "photo.on.rectangle")
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

                Section("Infos") {
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
                .onChange(of: isGraded) { _, newValue in
                    if !newValue {
                        gradeValue = ""
                        certificationNumber = ""
                    }
                }

                if let errorText {
                    Section("Erreur") {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Ajouter une carte")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "Ajout..." : "Ajouter") { save() }
                        .disabled(!canSave)
                }
            }
            .onChange(of: selectedItem) { _, newItem in
                guard let newItem else { return }
                loadImage(from: newItem)
            }
            .onAppear {
                // ✅ sécurité: AddCardView ne devrait jamais être utilisable sans ownerId
                if ownerId.trimmed.isEmpty {
                    errorText = "Erreur: utilisateur non connecté."
                }
            }
        }
    }

    private var canSave: Bool {
        if isSaving { return false }
        if ownerId.trimmed.isEmpty { return false }
        if title.trimmed.isEmpty { return false }
        return true
    }

    private func loadImage(from item: PhotosPickerItem) {
        errorText = nil
        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let finalData = compressIfNeeded(data)
                    await MainActor.run {
                        self.imageData = finalData
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    private func compressIfNeeded(_ data: Data) -> Data {
        guard let ui = UIImage(data: data) else { return data }
        return ui.jpegData(compressionQuality: 0.85) ?? data
    }

    private func save() {
        errorText = nil

        guard !ownerId.trimmed.isEmpty else {
            errorText = "Erreur: utilisateur non connecté."
            return
        }

        isSaving = true

        // ✅ ownerId requis dans ton modèle
        let newCard = CardItem(
            ownerId: ownerId.trimmed,
            title: title.trimmed,
            notes: notes.trimmed.isEmpty ? nil : notes.trimmed,
            frontImageData: imageData
        )

        // ✅ Fiche
        newCard.playerName = playerName.trimmed.nonEmptyOrNil
        newCard.cardYear = cardYear.trimmed.nonEmptyOrNil
        newCard.companyName = companyName.trimmed.nonEmptyOrNil
        newCard.setName = setName.trimmed.nonEmptyOrNil
        newCard.cardNumber = cardNumber.trimmed.nonEmptyOrNil

        // ✅ Grading
        newCard.isGraded = isGraded
        if isGraded {
            newCard.gradingCompany = gradingCompany.trimmed.nonEmptyOrNil
            newCard.gradeValue = gradeValue.trimmed.nonEmptyOrNil
            newCard.certificationNumber = certificationNumber.trimmed.nonEmptyOrNil
        } else {
            newCard.gradingCompany = nil
            newCard.gradeValue = nil
            newCard.certificationNumber = nil
        }

        modelContext.insert(newCard)

        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorText = error.localizedDescription
            isSaving = false
        }
    }
}

// MARK: - Preview image

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

// MARK: - String helpers

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmptyOrNil: String? { trimmed.isEmpty ? nil : trimmed }
}
