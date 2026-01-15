//
//  CardQuickEditView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-15.
//
import SwiftUI
import SwiftData

/// ✅ Édition rapide (sheet) pour modifier les champs les plus utilisés,
/// sans ouvrir la fiche complète.
struct CardQuickEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // ✅ SwiftData: on édite directement l’objet (Bindable)
    @Bindable var card: CardItem

    @State private var priceText: String = ""
    @State private var localNotes: String = ""
    @State private var localPlayer: String = ""
    @State private var localYear: String = ""
    @State private var localSet: String = ""

    @State private var errorText: String? = nil
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Carte") {
                    Text(card.title)
                        .font(.headline)
                        .lineLimit(2)

                    if let grading = card.gradingLabel {
                        Text(grading)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Valeur estimée") {
                    TextField("Ex: 25.00", text: $priceText)
                        .keyboardType(.decimalPad)

                    Text("En dollars CAD. Mets vide ou 0 si tu ne veux pas afficher de valeur.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Infos") {
                    TextField("Joueur", text: $localPlayer)
                        .textInputAutocapitalization(.words)

                    TextField("Année", text: $localYear)
                        .keyboardType(.numberPad)

                    TextField("Set", text: $localSet)
                        .textInputAutocapitalization(.words)

                    Text("Optionnel. Utile pour le regroupement et la recherche.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Notes") {
                    TextEditor(text: $localNotes)
                        .frame(minHeight: 110)

                    Text("Astuce : garde ça court, 1–2 lignes. Exemple : “Belle condition, acheté au expo 2025.”")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let errorText {
                    Section("Erreur") {
                        Text(errorText)
                            .foregroundStyle(.red)
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
                    Button(isSaving ? "Sauvegarde…" : "Enregistrer") {
                        save()
                    }
                    .disabled(isSaving)
                    .font(.headline)
                }
            }
            .onAppear {
                hydrateLocalState()
            }
        }
    }

    private func hydrateLocalState() {
        let v = card.estimatedPriceCAD ?? 0
        priceText = (v > 0) ? String(format: "%.2f", v) : ""

        localNotes = card.notes ?? ""
        localPlayer = card.playerName ?? ""
        localYear = card.cardYear ?? ""
        localSet = card.setName ?? ""
    }

    private func save() {
        errorText = nil
        isSaving = true

        // 1) Prix
        let parsed = parsePrice(priceText)
        if let parsed, parsed < 0 {
            errorText = "Le prix ne peut pas être négatif."
            isSaving = false
            return
        }

        // 2) Normalisation textes
        let notes = localNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let player = localPlayer.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = localYear.trimmingCharacters(in: .whitespacesAndNewlines)
        let set = localSet.trimmingCharacters(in: .whitespacesAndNewlines)

        // 3) Écriture SwiftData (direct sur l’objet)
        card.estimatedPriceCAD = (parsed ?? 0) > 0 ? (parsed ?? 0) : 0
        card.notes = notes.isEmpty ? nil : notes
        card.playerName = player.isEmpty ? nil : player
        card.cardYear = year.isEmpty ? nil : year
        card.setName = set.isEmpty ? nil : set

        do {
            try modelContext.save()
            isSaving = false
            dismiss()
        } catch {
            errorText = error.localizedDescription
            isSaving = false
        }
    }

    private func parsePrice(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }

        // supporte virgule ou point
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }
}

