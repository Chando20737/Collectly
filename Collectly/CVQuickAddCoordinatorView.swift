import SwiftUI
import SwiftData
import UIKit

// MARK: - CardDraft

/// Draft minimal issu du scan/OCR.
/// Tu peux le construire depuis ton OCR (front/back) puis lancer `CVQuickAddCoordinatorView`.
struct CardDraft: Equatable {
    var playerName: String = ""
    var year: Int? = nil
    var setName: String = ""
    var cardNumber: String = ""
    var teamName: String = ""
    var parallelOrInsert: String = ""
    var notes: String = ""

    /// Un titre lisible (fallback si pas assez d'infos).
    func bestTitle(fallbackDate: Date = Date()) -> String {
        let y = year.map { String($0) } ?? ""
        let pieces = [
            y,
            playerName.trimmedOrEmpty,
            setName.trimmedOrEmpty,
            cardNumber.trimmedOrEmpty.isEmpty ? "" : "#\(cardNumber.trimmedOrEmpty)"
        ].filter { !$0.isEmpty }

        if !pieces.isEmpty {
            return pieces.joined(separator: " ").condenseSpaces
        }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return "Carte \(df.string(from: fallbackDate))"
    }
}

// MARK: - Confidence

struct CardDraftConfidence {

    /// Score 0...1 basé sur la présence des champs.
    /// C'est volontairement simple et robuste.
    static func score(for draft: CardDraft) -> Double {
        var score: Double = 0

        let player = draft.playerName.trimmedOrEmpty
        let setName = draft.setName.trimmedOrEmpty
        let cardNo = draft.cardNumber.trimmedOrEmpty
        let team = draft.teamName.trimmedOrEmpty

        if player.count >= 3 { score += 0.35 }
        if setName.count >= 3 { score += 0.25 }
        if draft.year != nil { score += 0.15 }
        if cardNo.count >= 1 { score += 0.10 }
        if team.count >= 3 { score += 0.05 }
        if !draft.parallelOrInsert.trimmedOrEmpty.isEmpty { score += 0.05 }

        // Petit bonus si on a player + set + year
        if player.count >= 3, setName.count >= 3, draft.year != nil {
            score += 0.10
        }

        return min(1.0, max(0.0, score))
    }

    /// Seuil d'auto-save.
    static let autoSaveThreshold: Double = 0.75
}

// MARK: - View

/// Coordinator "ultra-rapide": auto-sauvegarde si confiance élevée, sinon écran de révision.
struct CVQuickAddCoordinatorView: View {

    let uid: String
    let frontImage: UIImage
    let backImage: UIImage?

    /// Draft pré-rempli par ton OCR (recommandé)
    let initialDraft: CardDraft

    /// Optionnel: fermer la feuille/écran parent
    var onFinished: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var draft: CardDraft
    @State private var didAttemptAutoSave = false
    @State private var isSaving = false
    @State private var errorText: String? = nil

    init(
        uid: String,
        frontImage: UIImage,
        backImage: UIImage? = nil,
        initialDraft: CardDraft,
        onFinished: (() -> Void)? = nil
    ) {
        self.uid = uid
        self.frontImage = frontImage
        self.backImage = backImage
        self.initialDraft = initialDraft
        self.onFinished = onFinished
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        let confidence = CardDraftConfidence.score(for: draft)

        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(uiImage: frontImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 86, height: 86)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(draft.bestTitle())
                                .font(.headline)
                                .lineLimit(2)

                            HStack(spacing: 8) {
                                Text("Confiance")
                                    .foregroundStyle(.secondary)
                                ProgressView(value: confidence)
                                    .frame(maxWidth: 120)
                                Text("\(Int(confidence * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        Spacer()
                    }
                }

                Section("Champs") {
                    TextField("Joueur", text: $draft.playerName)
                        .textInputAutocapitalization(.words)

                    TextField("Set (ex: Upper Deck Series 1)", text: $draft.setName)
                        .textInputAutocapitalization(.words)

                    TextField("Année (ex: 2024)", text: Binding(
                        get: { draft.year.map(String.init) ?? "" },
                        set: { draft.year = Int($0.trimmedOrEmpty) }
                    ))
                    .keyboardType(.numberPad)

                    TextField("Numéro (ex: 201)", text: $draft.cardNumber)

                    TextField("Équipe", text: $draft.teamName)
                        .textInputAutocapitalization(.words)

                    TextField("Parallèle / Insert", text: $draft.parallelOrInsert)
                        .textInputAutocapitalization(.words)
                }

                Section("Notes") {
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button {
                        saveCardAndClose()
                    } label: {
                        if isSaving {
                            HStack {
                                ProgressView()
                                Text("Sauvegarde...")
                            }
                        } else {
                            Text("Ajouter à Ma collection")
                        }
                    }
                    .disabled(isSaving || draft.bestTitle().trimmedOrEmpty.isEmpty)

                    if confidence >= CardDraftConfidence.autoSaveThreshold {
                        Text("Astuce: cette carte devrait pouvoir s'ajouter automatiquement après l'OCR (confiance \(Int(confidence * 100))%).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Confiance faible: vérifie rapidement les champs, puis ajoute.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Ajout rapide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Auto-save seulement une fois
                guard !didAttemptAutoSave else { return }
                didAttemptAutoSave = true

                let confidence = CardDraftConfidence.score(for: draft)
                if confidence >= CardDraftConfidence.autoSaveThreshold {
                    saveCardAndClose()
                }
            }
        }
    }

    private func saveCardAndClose() {
        errorText = nil
        guard !isSaving else { return }
        isSaving = true

        do {
            let title = draft.bestTitle()

            let frontData = frontImage.jpegData(compressionQuality: 0.85)
            let backData = backImage?.jpegData(compressionQuality: 0.85)

            // CardItem.swift (dans ton projet) contient ownerId, title, notes + imageData
            // On remplit notes avec une version enrichie.
            let enrichedNotes = buildEnrichedNotes(from: draft)

            let item = CardItem(
                ownerId: uid,
                title: title,
                notes: enrichedNotes,
                frontImageData: frontData,
                backImageData: backData
            )

            modelContext.insert(item)
            try modelContext.save()

            isSaving = false
            onFinished?()
            dismiss()
        } catch {
            isSaving = false
            errorText = "Erreur de sauvegarde SwiftData: \(error.localizedDescription)"
        }
    }

    private func buildEnrichedNotes(from draft: CardDraft) -> String {
        var lines: [String] = []

        let player = draft.playerName.trimmedOrEmpty
        let setName = draft.setName.trimmedOrEmpty
        let cardNo = draft.cardNumber.trimmedOrEmpty
        let team = draft.teamName.trimmedOrEmpty
        let parallel = draft.parallelOrInsert.trimmedOrEmpty

        if !player.isEmpty { lines.append("Player: \(player)") }
        if let y = draft.year { lines.append("Year: \(y)") }
        if !setName.isEmpty { lines.append("Set: \(setName)") }
        if !cardNo.isEmpty { lines.append("Card #: \(cardNo)") }
        if !team.isEmpty { lines.append("Team: \(team)") }
        if !parallel.isEmpty { lines.append("Parallel/Insert: \(parallel)") }

        let userNotes = draft.notes.trimmedOrEmpty
        if !userNotes.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(userNotes)
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - String helpers

private extension String {
    var trimmedOrEmpty: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var condenseSpaces: String {
        let parts = split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }
}
