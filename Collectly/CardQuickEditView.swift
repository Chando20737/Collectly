//
//  CardQuickEditView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-15.
//
import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct CardQuickEditView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Bindable var card: CardItem

    // ✅ Notes + valeur
    @State private var notes: String = ""
    @State private var priceText: String = ""

    // ✅ Quantité (UserDefaults)
    @State private var quantity: Int = 1

    // ✅ Photo
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var imageData: Data? = nil
    @State private var imageError: String? = nil

    var body: some View {
        NavigationStack {
            Form {

                // ✅ PHOTO
                Section("Photo") {
                    VStack(spacing: 12) {
                        CardQuickEditImagePreview(data: imageData)

                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label(imageData == nil ? "Ajouter une photo" : "Changer la photo",
                                  systemImage: "photo.on.rectangle")
                        }

                        if imageData != nil {
                            Button(role: .destructive) {
                                selectedPhotoItem = nil
                                imageData = nil
                            } label: {
                                Label("Retirer la photo", systemImage: "trash")
                            }
                        }

                        if let imageError, !imageError.isEmpty {
                            Text(imageError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("Carte") {
                    Text(card.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Quantité") {
                    Stepper(value: $quantity, in: 1...999) {
                        HStack {
                            Text("Nombre d’exemplaires")
                            Spacer()
                            Text("x\(quantity)")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Valeur estimée (CAD)") {
                    TextField("ex: 25.00", text: $priceText)
                        .keyboardType(.decimalPad)
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 110)
                }
            }
            .navigationTitle("Édition rapide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Enregistrer") {
                        save()
                        dismiss()
                    }
                    .font(.headline)
                }
            }
            .onAppear {
                notes = card.notes ?? ""
                priceText = card.estimatedPriceCAD.map { String(format: "%.2f", $0) } ?? ""

                // ✅ Charge la quantité depuis UserDefaults
                quantity = QuantityStore.quantity(id: card.id)

                // ✅ Charge l'image existante (si aucune: nil)
                imageData = card.frontImageData
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                loadImage(from: newItem)
            }
        }
    }

    // MARK: - Image loading

    private func loadImage(from item: PhotosPickerItem) {
        imageError = nil
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
                    self.imageError = error.localizedDescription
                }
            }
        }
    }

    private func compressIfNeeded(_ data: Data) -> Data {
        guard let ui = UIImage(data: data) else { return data }
        return ui.jpegData(compressionQuality: 0.85) ?? data
    }

    // MARK: - Save

    private func save() {
        // ✅ Photo
        card.frontImageData = imageData

        // Notes
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        card.notes = n.isEmpty ? nil : n

        // Valeur
        let cleaned = priceText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let v = Double(cleaned), v > 0 {
            card.estimatedPriceCAD = (v * 100).rounded() / 100
        } else {
            card.estimatedPriceCAD = nil
        }

        // ✅ Quantité (persistée)
        QuantityStore.setQuantity(quantity, id: card.id)

        // ✅ Persist SwiftData
        do {
            try modelContext.save()
        } catch {
            // Si jamais ça échoue, au moins on voit l’erreur en console
            print("❌ SwiftData save error (CardQuickEditView): \(error.localizedDescription)")
        }
    }
}

// MARK: - Preview component

private struct CardQuickEditImagePreview: View {
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
                    Text("Aucune photo")
                        .foregroundStyle(.secondary)
                }
            }

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 1)
        }
        .frame(height: 240)
    }
}

