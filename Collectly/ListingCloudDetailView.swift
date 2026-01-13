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

    @State private var liveListing: ListingCloud? = nil
    @State private var showEdit = false
    @State private var showRemoveConfirm = false

    @State private var showBidSheet = false
    @State private var isBuying = false

    @State private var errorText: String? = nil
    @State private var permissionDenied = false

    private let service = MarketplaceService()

    private var currentUid: String? { Auth.auth().currentUser?.uid }

    private var isOwner: Bool {
        guard let uid = currentUid else { return false }
        let l = liveListing ?? listing
        return uid == l.sellerId
    }

    private func isAuction(_ l: ListingCloud) -> Bool { l.type == "auction" }

    private func isAuctionEndedByTime(_ l: ListingCloud, now: Date) -> Bool {
        guard isAuction(l), let end = l.endDate else { return false }
        return end <= now
    }

    private func isAuctionEndingSoon(_ l: ListingCloud, now: Date) -> Bool {
        guard isAuction(l), let end = l.endDate else { return false }
        let remaining = end.timeIntervalSince(now)
        return remaining > 0 && remaining <= 60 * 60
    }

    private func auctionStatusText(_ l: ListingCloud, now: Date) -> String {
        if l.status == "ended" { return "Terminé" }
        if l.status == "sold" { return "Vendu" }
        if l.status == "paused" { return "En pause" }

        if isAuction(l) {
            if isAuctionEndedByTime(l, now: now) {
                return "Terminé (fermeture en cours)"
            }
            return "Actif"
        }

        return (l.status == "active") ? "Actif" : l.status
    }

    var body: some View {
        let l = liveListing ?? listing

        Form {

            Section {
                SlabListingImage(urlString: l.imageUrl)
                    .padding(.vertical, 6)
            }

            if permissionDenied {
                Section {
                    Text("Cette annonce n’est plus accessible (probablement retirée).")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorText {
                Section("Erreur") {
                    Text("❌ \(errorText)")
                        .foregroundStyle(.red)
                }
            }

            // ✅ Bandeau “Dernière minute” / “Terminé”
            if isAuction(l) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let now = ctx.date
                    if isAuctionEndedByTime(l, now: now) && l.status != "ended" {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                            Text("Encan terminé — fermeture en cours…")
                            Spacer()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    } else if isAuctionEndingSoon(l, now: now) && l.status == "active" {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill")
                            Text("Dernière minute")
                            Spacer()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section("Annonce") {
                Text(l.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                if let d = l.descriptionText, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(d)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Type")
                    Spacer()
                    Text(l.type == "fixedPrice" ? "Prix fixe" : "Encan")
                        .foregroundStyle(.secondary)
                }

                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let now = ctx.date
                    HStack {
                        Text("Statut")
                        Spacer()
                        Text(auctionStatusText(l, now: now))
                            .foregroundStyle(.secondary)
                    }
                }

                if isOwner {
                    Text("⚠️ C’est ton annonce")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }

            Section("Prix") {
                if l.type == "fixedPrice" {
                    if let p = l.buyNowPriceCAD {
                        Text(String(format: "%.0f $ CAD", p))
                    } else {
                        Text("Prix non défini")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let current = l.currentBidCAD ?? l.startingBidCAD ?? 0
                    Text(String(format: "Mise actuelle: %.0f $ CAD", current))
                    Text("Mises: \(l.bidCount)")
                        .foregroundStyle(.secondary)

                    if let end = l.endDate {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let now = ctx.date
                            Text("Temps restant: \(timeRemainingText(until: end, now: now))")
                                .font(.footnote)
                                .foregroundStyle(end <= now ? .red : .secondary)

                            Text("Se termine le \(end.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Fin: non définie")
                            .foregroundStyle(.secondary)
                    }

                    // ✅ “Plus offrant / dépassé”
                    if let uid = currentUid, !isOwner, l.bidCount > 0 {
                        let isLeading = (l.lastBidderId == uid)
                        Text(isLeading ? "✅ Tu es le plus offrant" : "⚠️ Tu as été dépassé")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(isLeading ? .green : .orange)
                    }
                }

                if let u = l.sellerUsername, !u.isEmpty {
                    Text("Vendeur : @\(u)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Actions") {

                // MARK: - Acheteur
                if !isOwner {
                    if l.type == "fixedPrice" {
                        Button(isBuying ? "Achat..." : "Acheter maintenant") {
                            buyNow(listingId: l.id)
                        }
                        .disabled(permissionDenied || isBuying || l.status != "active")
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let now = ctx.date
                            let endedByTime = isAuctionEndedByTime(l, now: now)
                            let canBid = (!permissionDenied) && (l.status == "active") && (!endedByTime)

                            Button("Miser") { showBidSheet = true }
                                .disabled(!canBid)

                            if endedByTime && l.status == "active" {
                                Text("Encan terminé. Il va disparaître du Marketplace sous peu.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // MARK: - Vendeur
                if isOwner && !permissionDenied {

                    if l.type == "fixedPrice" && l.status == "active" {
                        Button("Mettre en pause") { updateStatus(l.id, "paused") }
                    }
                    if l.type == "fixedPrice" && l.status == "paused" {
                        Button("Publier dans Marketplace") { updateStatus(l.id, "active") }
                    }

                    let hasBids = (l.bidCount > 0)

                    let canRemove = (l.status != "ended") && !(isAuction(l) && hasBids)
                    let canEditFixedPrice = (l.type == "fixedPrice" && (l.status == "active" || l.status == "paused"))
                    let canEditAuction = (isAuction(l) && l.status == "active" && !hasBids)
                    let canEdit = canEditFixedPrice || canEditAuction

                    if canEdit {
                        Button("Modifier l’annonce") { showEdit = true }
                    } else if isAuction(l) && hasBids && l.status == "active" {
                        Text("Impossible de modifier un encan lorsqu’il y a déjà des mises.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if canRemove {
                        Button("Retirer l’annonce", role: .destructive) {
                            showRemoveConfirm = true
                        }
                    } else if isAuction(l) && hasBids && l.status != "ended" {
                        Text("Impossible de retirer un encan lorsqu’il y a déjà des mises.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if isAuction(l) {
                        Text("Un encan ne peut pas être mis en pause.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)

        .onAppear { subscribeToListing() }
        .onDisappear { unsubscribe() }

        .sheet(isPresented: $showEdit) {
            // Si tu as déjà un ListingEditView, garde-le.
            ListingEditView(listing: liveListing ?? listing) { }
        }

        .sheet(isPresented: $showBidSheet) {
            let current = (l.currentBidCAD ?? 0)
            let start = (l.startingBidCAD ?? 0)
            let minRequired = max(current, start)

            BidSheetView(
                listingId: l.id,
                minBidCAD: minRequired,
                endDate: l.endDate,
                onBidPlaced: { }
            )
        }

        .alert("Retirer l’annonce ?", isPresented: $showRemoveConfirm) {
            Button("Annuler", role: .cancel) {}
            Button("Retirer", role: .destructive) { removeListing(listingId: l.id) }
        } message: {
            Text("L’annonce sera retirée du Marketplace (status = ended).")
        }
    }

    // MARK: - Live updates

    @State private var listener: ListenerRegistration?

    private func subscribeToListing() {
        unsubscribe()
        errorText = nil
        permissionDenied = false

        listener = Firestore.firestore()
            .collection("listings")
            .document(listing.id)
            .addSnapshotListener { snap, error in

                if let error {
                    let ns = error as NSError
                    if ns.domain == "FIRFirestoreErrorDomain" && ns.code == 7 {
                        self.permissionDenied = true
                        self.errorText = nil
                        return
                    }
                    self.errorText = error.localizedDescription
                    return
                }

                guard let snap else { return }

                if !snap.exists {
                    self.permissionDenied = true
                    return
                }

                guard let data = snap.data() else { return }

                // ✅ utilise TON mapping officiel
                self.liveListing = ListingCloud.fromData(docId: snap.documentID, data: data)
            }
    }

    private func unsubscribe() {
        listener?.remove()
        listener = nil
    }

    // MARK: - Actions

    private func buyNow(listingId: String) {
        errorText = nil
        isBuying = true

        Task {
            do {
                try await service.buyNow(listingId: listingId)
                await MainActor.run { isBuying = false }
            } catch {
                await MainActor.run {
                    isBuying = false
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func updateStatus(_ listingId: String, _ newStatus: String) {
        errorText = nil

        let ref = Firestore.firestore()
            .collection("listings")
            .document(listingId)

        ref.setData([
            "status": newStatus,
            "updatedAt": Timestamp(date: Date())
        ], merge: true) { error in
            if let error {
                self.errorText = error.localizedDescription
            }
        }
    }

    private func removeListing(listingId: String) {
        errorText = nil
        Task {
            do {
                try await service.endListing(listingId: listingId)
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Helpers (countdown)

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

// MARK: - Slab image

private struct SlabListingImage: View {
    let urlString: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.06))

            Group {
                if let urlString, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .padding(14)
                        case .failure:
                            placeholder
                        default:
                            ProgressView()
                        }
                    }
                } else {
                    placeholder
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.30), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 0.6)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 6)
        .frame(maxWidth: .infinity)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Image indisponible")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 26)
    }
}
