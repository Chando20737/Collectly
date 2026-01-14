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

    // ✅ Acheteur (actions)
    @State private var bidInput: String = ""
    @State private var showBuyConfirm: Bool = false
    @State private var showBidConfirm: Bool = false
    @State private var actionError: String? = nil
    @State private var actionSuccess: String? = nil

    private let db = Firestore.firestore()
    private let marketplace = MarketplaceService()

    init(listing: ListingCloud) {
        self.listing = listing
        _current = State(initialValue: listing)
    }

    // MARK: - Bindings (évite SwiftUI type-check problems)

    private var actionErrorPresented: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { newValue in if !newValue { actionError = nil } }
        )
    }

    private var actionSuccessPresented: Binding<Bool> {
        Binding(
            get: { actionSuccess != nil },
            set: { newValue in if !newValue { actionSuccess = nil } }
        )
    }

    // MARK: - FR plural (0 et 1 -> singulier)

    private func misesText(_ count: Int) -> String {
        return count <= 1 ? "\(count) mise" : "\(count) mises"
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
                        Text(current.buyNowPriceCAD == nil
                             ? "—"
                             : String(format: "%.2f $ CAD", current.buyNowPriceCAD ?? 0))
                        .foregroundStyle(.secondary)
                    }
                } else {
                    let currentBid = current.currentBidCAD ?? current.startingBidCAD ?? 0
                    let countText = misesText(current.bidCount)

                    Text(String(format: "Mise: %.2f $ CAD • %@", currentBid, countText))
                        .foregroundStyle(.secondary)

                    if let end = current.endDate {
                        Text("Temps restant: \(timeRemainingText(until: end))")
                            .font(.footnote)
                            .foregroundStyle(end <= Date() ? .red : .secondary)

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

            // MARK: - Buyer actions
            if !isOwner {
                Section("Actions") {
                    if current.type == "fixedPrice" {
                        buyNowActionBlock
                    } else {
                        auctionBidActionBlock
                    }

                    if !canInteractAsBuyer {
                        Text(buyerDisabledHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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

            // MARK: - Errors (Firestore listener / owner actions)
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

        // ✅ Confirmations
        .confirmationDialog(
            "Acheter maintenant?",
            isPresented: $showBuyConfirm,
            titleVisibility: .visible
        ) {
            Button("Confirmer l’achat", role: .destructive) {
                Task { await buyNow() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            let price = current.buyNowPriceCAD ?? 0
            Text("Tu vas acheter cette annonce pour \(String(format: "%.2f", price)) $ CAD.")
        }

        .confirmationDialog(
            "Confirmer ta mise?",
            isPresented: $showBidConfirm,
            titleVisibility: .visible
        ) {
            Button("Placer la mise", role: .destructive) {
                Task { await placeBid() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Montant: \(bidInput.trimmingCharacters(in: .whitespacesAndNewlines)) $ CAD")
        }

        // ✅ Alerts
        .alert("Erreur", isPresented: actionErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .alert("Succès", isPresented: actionSuccessPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionSuccess ?? "")
        }
    }

    // MARK: - Buyer UI blocks

    private var buyNowActionBlock: some View {
        VStack(alignment: .leading, spacing: 10) {

            let price = current.buyNowPriceCAD

            HStack {
                Text("Prix")
                Spacer()
                Text(price == nil ? "—" : String(format: "%.2f $ CAD", price ?? 0))
                    .foregroundStyle(.secondary)
            }

            Button {
                guard validateBuyNowBeforeConfirm() else { return }
                showBuyConfirm = true
            } label: {
                Label("Acheter maintenant", systemImage: "creditcard.fill")
            }
            .disabled(isWorking || !canBuyNow)

            Text("Une fois acheté, le statut passera à « Vendue ».")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var auctionBidActionBlock: some View {
        VStack(alignment: .leading, spacing: 10) {

            let minRequired = minimumBidRequired()

            HStack {
                Text("Mise minimale")
                Spacer()
                Text(String(format: "%.2f $ CAD", minRequired))
                    .foregroundStyle(.secondary)
            }

            TextField("Ta mise (CAD)", text: $bidInput)
                .keyboardType(.decimalPad)

            Button {
                guard validateBidBeforeConfirm() else { return }
                showBidConfirm = true
            } label: {
                Label("Miser", systemImage: "hammer.fill")
            }
            .disabled(isWorking || !canBid)

            Text("Ta mise doit être supérieure à la mise actuelle.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Ownership & buyer rules

    private var isOwner: Bool {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        return current.sellerId == uid
    }

    private var canTogglePause: Bool {
        if current.status == "sold" || current.status == "ended" { return false }
        if current.type == "auction" { return current.bidCount == 0 }
        return true
    }

    private var canEndNow: Bool {
        if current.status == "sold" || current.status == "ended" { return false }

        if current.type == "fixedPrice" {
            return current.status == "active" || current.status == "paused"
        }

        if current.type == "auction" {
            return (current.status == "active" || current.status == "paused") && current.bidCount == 0
        }

        return false
    }

    private var canInteractAsBuyer: Bool {
        guard current.status == "active" else { return false }

        if current.type == "auction" {
            guard let end = current.endDate else { return false }
            return end > Date()
        }
        return true
    }

    private var canBuyNow: Bool {
        guard !isOwner else { return false }
        guard current.type == "fixedPrice" else { return false }
        guard current.status == "active" else { return false }
        let p = current.buyNowPriceCAD ?? 0
        return p > 0
    }

    private var canBid: Bool {
        guard !isOwner else { return false }
        guard current.type == "auction" else { return false }
        guard current.status == "active" else { return false }
        guard let end = current.endDate, end > Date() else { return false }
        return true
    }

    private var buyerDisabledHint: String {
        if current.status != "active" {
            return "Cette annonce n’est pas active."
        }
        if current.type == "auction" && (current.endDate ?? Date()) <= Date() {
            return "Cet encan est terminé."
        }
        return "Action indisponible."
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

    // MARK: - Owner actions

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

    // MARK: - Buyer actions

    private func validateBuyNowBeforeConfirm() -> Bool {
        actionError = nil
        guard canBuyNow else {
            actionError = "Achat impossible pour cette annonce."
            return false
        }
        return true
    }

    private func buyNow() async {
        actionError = nil
        actionSuccess = nil
        guard canBuyNow else { return }

        isWorking = true
        defer { isWorking = false }

        do {
            try await marketplace.buyNow(listingId: current.id)
            await MainActor.run {
                actionSuccess = "Achat complété."
            }
        } catch {
            await MainActor.run {
                actionError = error.localizedDescription
            }
        }
    }

    private func validateBidBeforeConfirm() -> Bool {
        actionError = nil
        guard canBid else {
            actionError = "Mise impossible pour cet encan."
            return false
        }

        guard let bid = toDouble(bidInput), bid > 0 else {
            actionError = "Entre un montant valide (ex: 25)."
            return false
        }

        let minReq = minimumBidRequired()
        if bid <= minReq {
            actionError = "Ta mise doit être supérieure à \(String(format: "%.2f", minReq)) $ CAD."
            return false
        }

        return true
    }

    private func placeBid() async {
        actionError = nil
        actionSuccess = nil
        guard canBid else { return }

        guard let bid = toDouble(bidInput), bid > 0 else {
            actionError = "Entre un montant valide."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            try await marketplace.placeBid(listingId: current.id, bidCAD: bid)
            await MainActor.run {
                bidInput = ""
                actionSuccess = "Mise placée ✅"
            }
        } catch {
            await MainActor.run {
                actionError = error.localizedDescription
            }
        }
    }

    private func minimumBidRequired() -> Double {
        let starting = current.startingBidCAD ?? 0
        let currentBid = current.currentBidCAD ?? starting
        return max(currentBid, starting)
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

    private func timeRemainingText(until end: Date) -> String {
        let now = Date()
        if end <= now { return "Terminé" }

        let diff = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: end)
        let d = diff.day ?? 0
        let h = diff.hour ?? 0
        let m = diff.minute ?? 0

        if d > 0 { return "\(d) j \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        return "\(max(m, 1)) min"
    }

    private func toDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        return Double(t.replacingOccurrences(of: ",", with: "."))
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

