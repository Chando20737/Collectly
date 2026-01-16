//
//  CardQuickEditView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-15.
//
import SwiftUI
import SwiftData

struct CardQuickEditView: View {

    @Environment(\.dismiss) private var dismiss

    @Bindable var card: CardItem

    @State private var notes: String = ""
    @State private var priceText: String = ""

    // ✅ Quantité (UserDefaults)
    @State private var quantity: Int = 1

    var body: some View {
        NavigationStack {
            Form {

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
            }
        }
    }

    private func save() {
        // Notes
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        card.notes = n.isEmpty ? nil : n

        // Valeur
        let cleaned = priceText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let v = Double(cleaned), v > 0 {
            card.estimatedPriceCAD = v
        } else {
            card.estimatedPriceCAD = nil
        }

        // ✅ Quantité (persistée)
        QuantityStore.setQuantity(quantity, id: card.id)
    }
}
