//
//  CVScannerAddCardView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-17.
//
import SwiftUI
import SwiftData
import VisionKit
import UIKit

// MARK: - Scanner V2 : détecte un nom, mais AJOUT seulement sur bouton

struct CVScannerAddCardView: View {

    let ownerId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var recognizedText: String = ""

    @State private var candidate: String = ""
    @State private var stableHits: Int = 0
    @State private var lastCandidate: String = ""

    @State private var uiError: String? = nil
    @State private var showToast = false
    @State private var toastText = "Carte ajoutée"

    // Réglages
    private let requiredStableHits = 2 // juste pour “verrouiller” l'affichage (pas pour auto-save)
    private let maxWords = 3

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {

                DataScannerTextView(
                    recognizedText: $recognizedText,
                    onTextChanged: { text in
                        handle(text)
                    }
                )
                .ignoresSafeArea()

                bottomHUD
            }
            .navigationTitle("Scanner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    private var bottomHUD: some View {
        VStack(spacing: 10) {

            if showToast {
                CVToast(text: toastText)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 10) {

                HStack {
                    Image(systemName: "camera.viewfinder")
                        .foregroundStyle(.secondary)
                    Text("Détection")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("stable \(min(stableHits, requiredStableHits))/\(requiredStableHits)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule(style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                }

                if candidate.trimmedLocal.isEmpty {
                    Text("Vise le NOM du joueur (ex: Gabe Perreault)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                } else {
                    Text(candidate)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                if let uiError, !uiError.isEmpty {
                    Text("⚠️ \(uiError)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(isCandidateValidAndStable ? "OK — tu peux ajouter." : "On attend un vrai prénom + nom (lettres latines).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    Button(role: .cancel) {
                        // reset affichage
                        candidate = ""
                        stableHits = 0
                        lastCandidate = ""
                        uiError = nil
                    } label: {
                        Label("Réinitialiser", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        addNow()
                    } label: {
                        Label("Ajouter", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isCandidateValidAndStable)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Logic

    private func handle(_ text: String) {
        uiError = nil

        let cleaned = text.trimmedLocal
        recognizedText = cleaned

        if cleaned.isEmpty {
            candidate = ""
            stableHits = 0
            lastCandidate = ""
            return
        }

        let best = CardScanParser.bestCandidateName(from: cleaned, maxWords: maxWords)
        candidate = best

        updateStability(with: best)

        // petit feedback si c'est bon
        if isCandidateValidAndStable {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func updateStability(with c: String) {
        let t = c.trimmedLocal
        guard !t.isEmpty else {
            stableHits = 0
            lastCandidate = ""
            return
        }

        if t.lowercased() == lastCandidate.lowercased() {
            stableHits += 1
        } else {
            lastCandidate = t
            stableHits = 1
        }
    }

    private var isCandidateValidAndStable: Bool {
        CardScanParser.isValidPlayerFullName(candidate, maxWords: maxWords)
        && stableHits >= requiredStableHits
    }

    private func addNow() {
        uiError = nil

        let title = candidate.trimmedLocal
        guard CardScanParser.isValidPlayerFullName(title, maxWords: maxWords) else {
            uiError = "Nom invalide. Vise le prénom + nom."
            return
        }

        // ✅ IMPORTANT: plus de notes “Scan...”
        let card = CardItem(
            ownerId: ownerId,
            title: title,
            notes: nil,
            frontImageData: nil,
            estimatedPriceCAD: nil,
            playerName: title,
            cardYear: nil,
            companyName: nil,
            setName: nil,
            cardNumber: nil,
            isGraded: nil,
            gradingCompany: nil,
            gradeValue: nil,
            certificationNumber: nil
        )

        modelContext.insert(card)

        do {
            try modelContext.save()
            showToastNow("Carte ajoutée")
        } catch {
            uiError = error.localizedDescription
        }
    }

    private func showToastNow(_ text: String) {
        toastText = text
        withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
            showToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeOut(duration: 0.18)) {
                showToast = false
            }
        }
    }
}

// MARK: - UIKit Scanner bridge

private struct DataScannerTextView: UIViewControllerRepresentable {

    @Binding var recognizedText: String
    let onTextChanged: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )

        scanner.delegate = context.coordinator

        DispatchQueue.main.async {
            do { try scanner.startScanning() }
            catch { print("❌ startScanning error:", error.localizedDescription) }
        }

        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        if !uiViewController.isScanning {
            DispatchQueue.main.async {
                do { try uiViewController.startScanning() }
                catch { print("❌ restartScanning error:", error.localizedDescription) }
            }
        }
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(recognizedText: $recognizedText, onTextChanged: onTextChanged)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        @Binding var recognizedText: String
        let onTextChanged: (String) -> Void

        init(recognizedText: Binding<String>, onTextChanged: @escaping (String) -> Void) {
            self._recognizedText = recognizedText
            self.onTextChanged = onTextChanged
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            updateFromAllItems(allItems)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            updateFromAllItems(allItems)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            updateFromAllItems(allItems)
        }

        private func updateFromAllItems(_ allItems: [RecognizedItem]) {
            let lines: [String] = allItems.compactMap { item in
                guard case .text(let t) = item else { return nil }
                return t.transcript
            }

            let joined = lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if joined != recognizedText {
                recognizedText = joined
                onTextChanged(joined)
            }
        }
    }
}

// MARK: - Parser strict (empêche arabe, majuscules, 1 mot, etc.)

private enum CardScanParser {

    // On accepte seulement lettres latines + espaces + tiret + apostrophe
    private static let allowedNameChars: CharacterSet = {
        var cs = CharacterSet.letters
        cs.insert(charactersIn: " -'’")
        return cs
    }()

    static func bestCandidateName(from text: String, maxWords: Int) -> String {
        let lines = text
            .split(separator: "\n")
            .map { String($0).trimmedLocal }
            .filter { !$0.isEmpty }

        // Cherche une ligne valide
        for l in lines {
            if isValidPlayerFullName(l, maxWords: maxWords) {
                return normalize(l)
            }
        }

        return ""
    }

    static func isValidPlayerFullName(_ s: String, maxWords: Int) -> Bool {
        let t = s.trimmedLocal
        if t.count < 7 || t.count > 40 { return false }
        if !t.contains(" ") { return false } // 2 mots minimum

        // ✅ seulement caractères “nom”
        if t.unicodeScalars.contains(where: { !allowedNameChars.contains($0) }) {
            return false
        }

        let words = t
            .split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty }

        if words.count < 2 || words.count > maxWords { return false }
        if words.contains(where: { $0.count < 2 }) { return false }

        // ✅ rejette mots tout en MAJUSCULES (PERREAUL, DUNG)
        for w in words where w.count >= 4 {
            if w == w.uppercased() { return false }
        }

        // blacklist de bruit
        let lower = t.lowercased()
        let banned = ["command","upper","deck","trading","card","collection","series","rookie","autograph","patch","hockey","nhl","league","national","www","http"]
        if banned.contains(where: { lower.contains($0) }) { return false }

        // doit avoir assez de lettres
        let letters = t.filter { $0.isLetter }.count
        if letters < 8 { return false }

        return true
    }

    private static func normalize(_ s: String) -> String {
        s.split(separator: " ").map { String($0).trimmedLocal }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Toast + Helpers

private struct CVToast: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }
}

private extension String {
    var trimmedLocal: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
