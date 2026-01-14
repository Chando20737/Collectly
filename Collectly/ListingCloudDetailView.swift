//
//  ListingCloudDetailView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct ListingCloudDetailView: View {

    let listing: ListingCloud

    @Environment(\.dismiss) private var dismiss

    @State private var current: ListingCloud
    @State private var listener: ListenerRegistration?
    @State private var uiErrorText: String? = nil
    @State private var isWorking: Bool = false

    private let db = Firestore.firestore()

    init(listing: ListingCloud) {
        self.listing = listing
        _current = State(initialValue: listing)
    }

    var body: some View {
        Form {

            // MARK: - Image
            Section {
                ListingRemoteHeroImage(urlString: current.imageUrl)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            // MARK: - Main info
            Section {
                Text(current.title)
                    .font(.headline)

                if let d = current.descriptionText, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(d)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - Listing info
            Section("Annonce") {

                HStack {
                    Text("Type")
                    Spacer()
                    Text(current.type == "fixedPrice" ? "Prix fixe" : "Encan")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Statut")
                    Spacer()
                    Text(statusLabel(current.status))
                        .foregroundStyle(.secondary)
                }

                if current.type == "fixedPrice" {
                    HStack {
                        Text("Prix")
                        Spacer()
                        Text(current.buyNowPriceCAD == nil ? "—" : String(format: "%.2f $ CAD", current.buyNowPriceCAD ?? 0))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let currentBid = current.currentBidCAD ?? current.startingBidCAD ?? 0
                    Text(String(format: "Mise: %.2f $ CAD • %d mises", currentBid, current.bidCount))
                        .foregroundStyle(.secondary)

                    if let end = current.endDate {
                        Text("Se termine le \(end.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let u = current.sellerUsername, !u.isEmpty {
                    Text("@\(u)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - Owner controls
            if isOwner {
                Section("Gestion") {

                    Button {
                        Task { await togglePauseResume() }
                    } label: {
                        Label(
                            current.status == "paused" ? "Réactiver" : "Mettre en pause",
                            systemImage: current.status == "paused" ? "play.circle.fill" : "pause.circle.fill"
                        )
                    }
                    .disabled(isWorking || !canTogglePause)

                    if canEndNow {
                        Button(role: .destructive) {
                            Task { await endListingNow() }
                        } label: {
                            Label("Retirer l’annonce", systemImage: "xmark.circle")
                        }
                        .disabled(isWorking)
                    }

                    Text(ownerHintText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - Errors
            if let uiErrorText {
                Section("Erreur") {
                    Text(uiErrorText)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Annonce")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Fermer") { dismiss() }
                    .disabled(isWorking)
            }
        }
        .onAppear { startListening() }
        .onDisappear { stopListening() }
    }

    // MARK: - Ownership & rules

    private var isOwner: Bool {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        return current.sellerId == uid
    }

    private var canTogglePause: Bool {
        // On permet pause/resume uniquement si l’annonce n’est pas sold/ended
        if current.status == "sold" || current.status == "ended" { return false }

        // Pour un encan, on peut mettre en pause seulement s'il n'y a aucune mise
        if current.type == "auction" {
            return current.bidCount == 0
        }

        // Prix fixe: ok tant que pas sold/ended
        return true
    }

    private var canEndNow: Bool {
        // Retirer l’annonce
        if current.status == "sold" || current.status == "ended" { return false }

        if current.type == "fixedPrice" {
            // active/paused -> ok
            return current.status == "active" || current.status == "paused"
        }

        if current.type == "auction" {
            // seulement si active ET aucune mise
            return current.status == "active" && current.bidCount == 0
        }

        return false
    }

    private var ownerHintText: String {
        if current.status == "paused" {
            return "En pause: l’annonce n’apparaît plus dans Marketplace, mais reste dans « Mes annonces »."
        }
        if current.status == "active" {
            return "Active: visible dans Marketplace."
        }
        if current.status == "sold" {
            return "Vendue: aucune modification possible."
        }
        if current.status == "ended" {
            return "Terminée: aucune modification possible."
        }
        return ""
    }

    // MARK: - Firestore live update

    private func startListening() {
        stopListening()
        uiErrorText = nil

        listener = db.collection("listings")
            .document(current.id)
            .addSnapshotListener { snap, error in
                if let error {
                    self.uiErrorText = error.localizedDescription
                    return
                }
                guard let snap, snap.exists else { return }
                self.current = ListingCloud.fromFirestore(doc: snap)
            }
    }

    private func stopListening() {
        listener?.remove()
        listener = nil
    }

    // MARK: - Actions

    private func togglePauseResume() async {
        guard isOwner else { return }
        guard canTogglePause else { return }

        uiErrorText = nil
        isWorking = true
        defer { isWorking = false }

        let ref = db.collection("listings").document(current.id)
        let nextStatus = (current.status == "paused") ? "active" : "paused"

        do {
            try await ref.updateData([
                "status": nextStatus,
                "updatedAt": Timestamp(date: Date())
            ])
        } catch {
            uiErrorText = error.localizedDescription
        }
    }

    private func endListingNow() async {
        guard isOwner else { return }
        guard canEndNow else { return }

        uiErrorText = nil
        isWorking = true
        defer { isWorking = false }

        let ref = db.collection("listings").document(current.id)
        let now = Timestamp(date: Date())

        do {
            try await ref.updateData([
                "status": "ended",
                "endedAt": now,
                "updatedAt": now
            ])
        } catch {
            uiErrorText = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func statusLabel(_ s: String) -> String {
        switch s {
        case "active": return "Active"
        case "paused": return "En pause"
        case "sold": return "Vendue"
        case "ended": return "Terminée"
        default: return s
        }
    }
}

// MARK: - Remote hero image

private struct ListingRemoteHeroImage: View {
    let urlString: String?

    var body: some View {
        Group {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    case .failure:
                        placeholder
                    default:
                        ProgressView()
                            .padding(.vertical, 18)
                    }
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.secondary.opacity(0.12))

            VStack(spacing: 10) {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                Text("Aucune image")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 240)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
