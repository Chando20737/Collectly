//
//  QuickImportSheetView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-15.
//
import SwiftUI
import PhotosUI
import UIKit

struct QuickImportSheetView: View {
    let onPickedImageData: (Data) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var photosItem: PhotosPickerItem? = nil
    @State private var isLoading = false
    @State private var errorText: String? = nil

    @State private var showCamera = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Import rapide") {
                    PhotosPicker(selection: $photosItem, matching: .images, photoLibrary: .shared()) {
                        Label("Importer depuis Photos", systemImage: "photo.on.rectangle")
                    }
                    .disabled(isLoading)

                    Button {
                        showCamera = true
                    } label: {
                        Label("Prendre une photo", systemImage: "camera")
                    }
                    .disabled(isLoading || !UIImagePickerController.isSourceTypeAvailable(.camera))
                }

                if isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Import en cours…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorText {
                    Section("Erreur") {
                        Text(errorText).foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Fermer", role: .cancel) {
                        dismiss()
                    }
                    .disabled(isLoading)
                }
            }
            .navigationTitle("Import rapide")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: photosItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadFromPhotosPicker(newItem) }
            }
            .sheet(isPresented: $showCamera) {
                ImagePicker(sourceType: .camera) { image in
                    handlePickedUIImage(image)
                }
                .ignoresSafeArea()
            }
        }
    }

    @MainActor
    private func loadFromPhotosPicker(_ item: PhotosPickerItem) async {
        errorText = nil
        isLoading = true
        defer { isLoading = false }

        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                onPickedImageData(data)
                dismiss()
            } else {
                errorText = "Impossible de lire l’image."
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func handlePickedUIImage(_ image: UIImage) {
        errorText = nil
        isLoading = true

        // Compression raisonnable
        let data = image.jpegData(compressionQuality: 0.88)

        isLoading = false

        guard let data else {
            errorText = "Impossible de convertir la photo."
            return
        }

        onPickedImageData(data)
        dismiss()
    }
}
