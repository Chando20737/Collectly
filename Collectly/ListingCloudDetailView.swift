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

    @EnvironmentObject private var session: SessionStore

    // Input (peut être “stale” / id pas fiable)
    let listing: ListingCloud

    // Live query listener
    @State private var docListener: ListenerRegistration?
    @State private var current: ListingCloud

    // ✅ Service (miser / acheter via rules-friendly writes)
    private let marketplaceService = MarketplaceService()

    // Micro-UX
    @State private var toast: Toast? = nil
    @State private var isBuying: Bool = false
    @State private var isBidding: Bool = false

    // Bid UI
    @State private var showBidSheet: Bool = false
    @State private var bidAmountText: String = ""

    // MARK: - Init

    init(listing: ListingCloud) {
        self.listing = listing
        _current = State(initialValue: listing)
    }

    // MARK: - Constants

    private let listingsCollection = "listings"
    private let minBidIncrement: Double = 1

    // MARK: - Computed

    private var uid: String? { session.user?.uid }

    private var isOwner: Bool {
        guard let uid else { return false }
        return current.sellerId == uid
    }

    private var isAuction: Bool { current.type == "auction" }
    private var isFixed: Bool { current.type == "fixedPrice" }

    private var isActive: Bool { current.status == "active" }

    private var endDate: Date? { current.endDate }

    private var hasEndedByTime: Bool {
        guard let endDate else { return false }
        return endDate <= Date()
    }

    private var canBid: Bool {
        guard uid != nil else { return false }
        guard isAuction else { return false }
        guard isActive else { return false }
        guard !hasEndedByTime else { return false }
        return !isOwner
    }

    private var canBuyNow: Bool {
        guard uid != nil else { return false }
        guard isActive else { return false }
        guard !hasEndedByTime else { return false }
        return !isOwner && buyNowPriceCAD > 0
    }

    private var currentBidCAD: Double {
        current.currentBidCAD ?? current.startingBidCAD ?? 0
    }

    private var buyNowPriceCAD: Double {
        current.buyNowPriceCAD ?? 0
    }

    private var nextMinBid: Double {
        max(currentBidCAD + minBidIncrement, minBidIncrement)
    }

    private var frostedBG: AnyShapeStyle {
        if #available(iOS 15.0, *) {
            return AnyShapeStyle(.ultraThinMaterial)
        } else {
            return AnyShapeStyle(Color(.secondarySystemBackground).opacity(0.95))
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                headerImage
                titleBlock
                metaBlock

                if let desc = current.descriptionText,
                   !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    descriptionBlock(desc)
                }

                actionBlock

                Spacer(minLength: 14)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
        .navigationTitle("Annonce")
        .navigationBarTitleDisplayMode(.inline)
        .toast($toast)
        .onAppear { startDocListener() }
        .onDisappear { stopDocListener() }
        .sheet(isPresented: $showBidSheet) {
            bidSheet
        }
    }

    // MARK: - UI blocks

    private var headerImage: some View {
        ZStack(alignment: .topTrailing) {

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))

                if let urlString = current.imageUrl,
                   let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .padding(10)
                        case .failure:
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        default:
                            ProgressView()
                        }
                    }
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.10), lineWidth: 1)
            )

            VStack(alignment: .trailing, spacing: 8) {

                if current.shouldShowGradingBadge, let label = current.gradingLabel {
                    GradingOverlayBadge(label: label, compact: false)
                }

                if let badge = current.statusBadge, current.status != "active" {
                    MyStatusChip(
                        text: badge.text,
                        systemImage: badge.icon,
                        color: badge.color,
                        backgroundOpacity: badge.backgroundOpacity,
                        strokeOpacity: badge.strokeOpacity,
                        isOverlayOnImage: true
                    )
                }

                if isAuction, isActive, let end = endDate {
                    EndingSoonOrRemainingChip(endDate: end)
                }
            }
            .padding(.top, 10)
            .padding(.trailing, 10)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {

            Text(current.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                ListingBadgeView(
                    text: current.typeBadge.text,
                    systemImage: current.typeBadge.icon,
                    color: current.typeBadge.color
                )

                if let u = current.sellerUsername, !u.isEmpty {
                    Text("@\(u)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var metaBlock: some View {
        VStack(alignment: .leading, spacing: 10) {

            if isAuction {
                HStack(spacing: 10) {
                    infoPill(title: "Mise actuelle", value: money(currentBidCAD))
                    infoPill(title: "Mises", value: "\(current.bidCount)")
                }

                if let end = endDate {
                    infoRow(systemImage: "clock", text: "Fin: \(end.formatted(date: .abbreviated, time: .shortened))")
                }

            } else {
                infoPillWide(title: "Prix", value: buyNowPriceCAD > 0 ? money(buyNowPriceCAD) : "Non défini")
            }

            if current.status == "sold" {
                let soldPrice = current.finalPriceCAD ?? current.currentBidCAD ?? current.buyNowPriceCAD ?? 0
                infoRow(systemImage: "checkmark.seal.fill", text: "Vendu • \(money(soldPrice))")
            }

            if current.status == "ended" {
                infoRow(systemImage: "flag.checkered", text: "Annonce terminée")
            }

            if current.status == "paused" {
                infoRow(systemImage: "pause.circle.fill", text: "Annonce en pause")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func descriptionBlock(_ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)

            Text(desc)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var actionBlock: some View {
        VStack(spacing: 10) {

            if uid == nil {
                actionHint("Connecte-toi pour miser ou acheter.", icon: "person.crop.circle.badge.exclamationmark")

            } else if isOwner {
                actionHint("C’est ton annonce.", icon: "person.fill.checkmark")

            } else if !isActive || hasEndedByTime {
                actionHint("Cette annonce n’est plus active.", icon: "xmark.circle.fill")

            } else {
                if isAuction {
                    HStack(spacing: 10) {
                        ActionButton(
                            title: "Miser",
                            systemImage: "hammer.fill",
                            style: .primary,
                            isLoading: isBidding,
                            isDisabled: !canBid || isBuying
                        ) { bidTapped() }

                        if buyNowPriceCAD > 0 {
                            ActionButton(
                                title: "Acheter",
                                systemImage: "cart.fill",
                                style: .secondary,
                                isLoading: isBuying,
                                isDisabled: !canBuyNow || isBidding
                            ) { buyNowTapped() }
                        }
                    }

                    Text("Mise minimale: \(money(nextMinBid))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)

                } else {
                    ActionButton(
                        title: "Acheter maintenant",
                        systemImage: "cart.fill",
                        style: .primary,
                        isLoading: isBuying,
                        isDisabled: !canBuyNow || isBidding
                    ) { buyNowTapped() }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Bid sheet

    private var bidSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {

                Text(current.title)
                    .font(.headline)
                    .lineLimit(2)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Montant")
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 10) {
                        TextField("\(Int(nextMinBid))", text: $bidAmountText)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(frostedBG)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("$ CAD")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text("Minimum: \(money(nextMinBid))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ActionButton(
                    title: "Confirmer la mise",
                    systemImage: "checkmark.circle.fill",
                    style: .primary,
                    isLoading: isBidding,
                    isDisabled: !canBid || isBuying
                ) { confirmBidFromSheet() }
            }
            .padding(16)
            .navigationTitle("Miser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") {
                        Haptic.light()
                        showBidSheet = false
                    }
                }
            }
            .onAppear {
                bidAmountText = String(Int(nextMinBid))
            }
        }
    }

    // MARK: - Actions

    private func bidTapped() {
        guard canBid else {
            toast = Toast(style: .info, title: "Impossible de miser maintenant.", systemImage: "info.circle")
            Haptic.error()
            return
        }
        Haptic.light()
        showBidSheet = true
    }

    private func confirmBidFromSheet() {
        guard uid != nil else { return }

        let raw = bidAmountText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let amount = Double(raw), amount > 0 else {
            toast = Toast(style: .error, title: "Montant invalide.", systemImage: "exclamationmark.triangle.fill")
            Haptic.error()
            return
        }

        guard amount >= nextMinBid else {
            toast = Toast(style: .error, title: "Mise trop basse. Minimum \(money(nextMinBid)).", systemImage: "arrow.up.circle.fill")
            Haptic.error()
            return
        }

        let listingId = resolvedListingId()
        guard !listingId.isEmpty else {
            toast = Toast(style: .error, title: "Annonce introuvable (id manquant).", systemImage: "exclamationmark.triangle.fill")
            Haptic.error()
            return
        }

        isBidding = true
        Haptic.light()

        Task {
            do {
                try await marketplaceService.placeBid(listingId: listingId, bidCAD: amount)
                await MainActor.run {
                    self.isBidding = false
                    self.showBidSheet = false
                    self.toast = Toast(style: .success, title: "Mise envoyée ✅", systemImage: "checkmark.circle.fill")
                    Haptic.success()
                }
            } catch {
                await MainActor.run {
                    self.isBidding = false
                    self.toast = Toast(style: .error, title: error.localizedDescription, systemImage: "exclamationmark.triangle.fill", duration: 2.8)
                    Haptic.error()
                }
            }
        }
    }

    private func buyNowTapped() {
        guard canBuyNow else {
            toast = Toast(style: .info, title: "Impossible d’acheter maintenant.", systemImage: "info.circle")
            Haptic.error()
            return
        }

        guard buyNowPriceCAD > 0 else {
            toast = Toast(style: .error, title: "Prix d’achat non défini.", systemImage: "exclamationmark.triangle.fill")
            Haptic.error()
            return
        }

        let listingId = resolvedListingId()
        guard !listingId.isEmpty else {
            toast = Toast(style: .error, title: "Annonce introuvable (id manquant).", systemImage: "exclamationmark.triangle.fill")
            Haptic.error()
            return
        }

        isBuying = true
        Haptic.light()

        Task {
            do {
                try await marketplaceService.buyNow(listingId: listingId)
                await MainActor.run {
                    self.isBuying = false
                    self.toast = Toast(style: .success, title: "Achat réussi ✅", systemImage: "checkmark.seal.fill")
                    Haptic.success()
                }
            } catch {
                await MainActor.run {
                    self.isBuying = false
                    self.toast = Toast(style: .error, title: error.localizedDescription, systemImage: "exclamationmark.triangle.fill", duration: 2.8)
                    Haptic.error()
                }
            }
        }
    }

    // MARK: - Firestore listener (document by id, avec gestion permission denied)

    private func startDocListener() {
        stopDocListener()

        let listingId = resolvedListingId()
        guard !listingId.isEmpty else { return }

        let db = Firestore.firestore()
        let ref = db.collection(listingsCollection).document(listingId)

        docListener = ref.addSnapshotListener { snap, err in
            if let ns = err as NSError? {
                // Permission denied (FIRFirestoreErrorDomain code 7)
                if ns.domain == "FIRFirestoreErrorDomain" && ns.code == 7 {
                    DispatchQueue.main.async {
                        self.toast = Toast(
                            style: .info,
                            title: "Annonce non accessible (permissions).",
                            systemImage: "lock.fill",
                            duration: 2.6
                        )
                    }
                    self.stopDocListener()
                    return
                }

                DispatchQueue.main.async {
                    self.toast = Toast(style: .error, title: ns.localizedDescription, systemImage: "exclamationmark.triangle.fill", duration: 2.8)
                }
                return
            }

            guard let snap else { return }

            if !snap.exists {
                DispatchQueue.main.async {
                    self.toast = Toast(style: .info, title: "Annonce introuvable.", systemImage: "info.circle", duration: 2.2)
                }
                return
            }

            let fresh = ListingCloud.fromFirestore(doc: snap)
            DispatchQueue.main.async {
                self.current = fresh
            }
        }
    }

    private func stopDocListener() {
        docListener?.remove()
        docListener = nil
    }

    private func resolvedListingId() -> String {
        // priorité à current.id si déjà “live”
        if !current.id.isEmpty { return current.id }
        if !listing.id.isEmpty { return listing.id }
        return ""
    }

    // MARK: - Helpers

    private func money(_ value: Double) -> String {
        return String(format: "%.0f $ CAD", value)
    }

    private func infoRow(systemImage: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func infoPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(frostedBG)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func infoPillWide(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(frostedBG)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func actionHint(_ text: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Micro components (local)

private struct ActionButton: View {

    enum Style { case primary, secondary }

    let title: String
    let systemImage: String
    let style: Style
    let isLoading: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button { action() } label: {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                }

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(UXButtonStyle(style: style, isDisabled: isDisabled || isLoading))
        .disabled(isDisabled || isLoading)
    }
}

private struct UXButtonStyle: ButtonStyle {

    let style: ActionButton.Style
    let isDisabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed

        return configuration.label
            .foregroundStyle(foregroundColor(pressed: pressed))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(backgroundColor(pressed: pressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .opacity(isDisabled ? 0.55 : (pressed ? 0.92 : 1.0))
            .scaleEffect(pressed ? 0.985 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.86), value: pressed)
    }

    private var borderColor: Color {
        switch style {
        case .primary: return Color.white.opacity(0.15)
        case .secondary: return Color.black.opacity(0.10)
        }
    }

    private func backgroundColor(pressed: Bool) -> Color {
        switch style {
        case .primary:
            return pressed ? Color.blue.opacity(0.88) : Color.blue
        case .secondary:
            return pressed ? Color(.secondarySystemGroupedBackground).opacity(0.92) : Color(.secondarySystemGroupedBackground)
        }
    }

    private func foregroundColor(pressed: Bool) -> Color {
        switch style {
        case .primary: return .white
        case .secondary: return .primary
        }
    }
}

private struct EndingSoonOrRemainingChip: View {

    let endDate: Date
    private let soonThreshold: TimeInterval = 24 * 60 * 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let remaining = endDate.timeIntervalSince(context.date)

            if remaining <= 0 {
                chip(text: "Terminé", sf: "xmark.circle.fill", color: .secondary)
            } else if remaining <= soonThreshold {
                chip(text: "Se termine bientôt", sf: "clock.fill", color: .orange)
            } else {
                chip(text: "Reste \(formatRemaining(remaining))", sf: "clock", color: .secondary)
            }
        }
    }

    private func chip(text: String, sf: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: sf).font(.caption2)
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(.systemBackground).opacity(0.92)))
        .overlay(Capsule().stroke(color.opacity(0.28), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.10), radius: 2, x: 0, y: 1)
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let m = s / 60
        let h = m / 60
        let d = h / 24

        if d > 0 { return "\(d)j \(h % 24)h" }
        if h > 0 { return "\(h)h \(m % 60)m" }
        return "\(m)m"
    }
}


