//
//  BidSheetView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-11.
//
import SwiftUI
import Combine

struct BidSheetView: View {
    let listingId: String
    let minBidCAD: Double
    let endDate: Date?
    let onBidPlaced: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var bidText: String = ""
    @State private var isSubmitting = false
    @State private var errorText: String?

    @State private var now: Date = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let service = MarketplaceService()

    var body: some View {
        NavigationStack {
            Form {

                if let endDate {
                    Section("Encan") {
                        let ended = endDate <= now

                        Text("Temps restant: \(timeRemainingText(until: endDate, now: now))")
                            .font(.footnote)
                            .foregroundStyle(ended ? .red : .secondary)

                        if ended {
                            Text("Cet encan est terminé. Tu ne peux plus miser.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Ta mise") {
                    TextField("Montant (CAD)", text: $bidText)
                        .keyboardType(.decimalPad)

                    Text("Minimum: \(String(format: "%.0f", minBidCAD + 1)) $ CAD")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let errorText {
                    Section("Erreur") {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    let ended = (endDate != nil && (endDate! <= now))

                    Button(isSubmitting ? "Envoi..." : "Miser") {
                        submit()
                    }
                    .disabled(isSubmitting || ended)
                }
            }
            .navigationTitle("Miser")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                        .disabled(isSubmitting)
                }
            }
        }
        .onAppear {
            bidText = String(format: "%.0f", minBidCAD + 1)
            now = Date()
        }
        .onReceive(timer) { value in
            now = value
        }
    }

    private func submit() {
        errorText = nil

        if let endDate, endDate <= Date() {
            errorText = "Cet encan est terminé."
            return
        }

        guard let amount = toDouble(bidText), amount > 0 else {
            errorText = "Entre un montant valide."
            return
        }

        if amount <= minBidCAD {
            errorText = "Ta mise doit être plus grande que \(String(format: "%.0f", minBidCAD)) $."
            return
        }

        isSubmitting = true

        Task {
            do {
                try await service.placeBid(listingId: listingId, bidCAD: amount)

                await MainActor.run {
                    isSubmitting = false
                    onBidPlaced()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func toDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        return Double(t.replacingOccurrences(of: ",", with: "."))
    }

    private func timeRemainingText(until end: Date, now: Date) -> String {
        if end <= now { return "Terminé" }

        let diff = Calendar.current.dateComponents([.day, .hour, .minute, .second], from: now, to: end)
        let d = diff.day ?? 0
        let h = diff.hour ?? 0
        let m = diff.minute ?? 0
        let s = diff.second ?? 0

        if d > 0 { return "\(d) j \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min \(max(s, 0)) s" }
        return "\(max(s, 1)) s"
    }
}
