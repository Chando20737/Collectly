//
//  MyListingsHubView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-14.
//
import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct MyListingsHubView: View {

    @EnvironmentObject private var session: SessionStore
    private let repo = MarketplaceRepository()

    @State private var listener: ListenerRegistration?
    @State private var listings: [ListingCloud] = []
    @State private var errorText: String?

    @State private var query: String = ""
    @State private var typeFilter: TypeFilter = .all

    // ✅ Même UX que Marketplace
    @AppStorage("myListingsViewMode") private var viewModeRaw: String = ViewMode.grid.rawValue
    private var viewMode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .grid }

    // ✅ Micro-UX
    @State private var isRefreshing: Bool = false
    @State private var toast: Toast? = nil

    enum ViewMode: String { case list, grid }

    enum TypeFilter: String, CaseIterable, Identifiable {
        case all = "Tous"
        case auctions = "Encans"
        case fixed = "Acheter maintenant"
        var id: String { rawValue }
    }

    // ✅ Donne assez d’espace au titre à gauche (évite “Me..”)
    // Ajuste 150 → 170 si tu ajoutes d’autres boutons à droite.
    private var leadingTitleWidth: CGFloat {
        max(220, UIScreen.main.bounds.width - 150)
    }

    var body: some View {
        NavigationStack {

            Group {
                if session.user == nil {

                    ContentUnavailableView(
                        "Mes annonces",
                        systemImage: "tray.full",
                        description: Text("Connecte-toi pour gérer tes ventes et tes enchères.")
                    )

                } else {

                    VStack(spacing: 6) {

                        topControls
                            .padding(.horizontal, 10)
                            .padding(.top, 2)

                        Group {
                            if let errorText {
                                ContentUnavailableView(
                                    "Erreur",
                                    systemImage: "exclamationmark.triangle",
                                    description: Text(errorText)
                                )
                            } else if filtered.isEmpty {
                                ContentUnavailableView(
                                    "Aucune annonce",
                                    systemImage: "tray.full",
                                    description: Text("Aucune annonce correspondant à ce filtre.")
                                )
                            } else {
                                if viewMode == .grid {
                                    gridMode
                                } else {
                                    listMode
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            // ✅ On ne met PAS navigationTitle("Mes annonces") sinon iOS le centre.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)

            .toolbar {

                // ✅ Titre à gauche, avec largeur fixe suffisante => pas tronqué
                ToolbarItem(placement: .topBarLeading) {
                    Text("Mes annonces")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: leadingTitleWidth, alignment: .leading)
                }

                // ✅ Actions à droite
                ToolbarItemGroup(placement: .topBarTrailing) {

                    Button {
                        Haptic.light()
                        viewModeRaw = (viewMode == .grid) ? ViewMode.list.rawValue : ViewMode.grid.rawValue
                        toast = Toast(
                            style: .info,
                            title: viewMode == .grid ? "Mode liste" : "Mode grille",
                            systemImage: "sparkles"
                        )
                    } label: {
                        Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                    }

                    Button {
                        refreshTapped()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .animation(
                                isRefreshing
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                : .default,
                                value: isRefreshing
                            )
                    }
                    .disabled(isRefreshing)
                }
            }
            .onAppear { startListening() }
            .onDisappear { stopListening() }
        }
        .toast($toast)
    }

    // MARK: - Top controls

    private var topControls: some View {
        VStack(spacing: 6) {

            Picker("Filtre", selection: $typeFilter) {
                ForEach(TypeFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: typeFilter) { _, _ in
                Haptic.light()
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Rechercher une annonce…", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !query.isEmpty {
                    Button {
                        Haptic.light()
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(frostedBG)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var frostedBG: AnyShapeStyle {
        if #available(iOS 15.0, *) {
            return AnyShapeStyle(.ultraThinMaterial)
        } else {
            return AnyShapeStyle(Color(.secondarySystemBackground).opacity(0.95))
        }
    }

    // MARK: - Filter

    private var filtered: [ListingCloud] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return listings
            .filter { l in
                switch typeFilter {
                case .all: return true
                case .auctions: return l.type == "auction"
                case .fixed: return l.type == "fixedPrice"
                }
            }
            .filter { l in
                guard !q.isEmpty else { return true }
                let hay = (l.title + " " + (l.descriptionText ?? "")).lowercased()
                return hay.contains(q)
            }
            .sorted { a, b in
                // ✅ Encans fin bientôt d'abord, sinon récents
                if a.type != b.type { return a.type == "auction" }
                if a.type == "auction" && b.type == "auction" {
                    let da = a.endDate ?? .distantFuture
                    let db = b.endDate ?? .distantFuture
                    if da != db { return da < db }
                    return a.createdAt > b.createdAt
                }
                return a.createdAt > b.createdAt
            }
    }

    // MARK: - Grid / List

    private var gridMode: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10, alignment: .top),
                    GridItem(.flexible(), spacing: 10, alignment: .top)
                ],
                spacing: 10
            ) {
                ForEach(filtered) { listing in
                    NavigationLink {
                        ListingCloudDetailView(listing: listing)
                    } label: {
                        MyListingsGridCardDense(listing: listing, miseText: miseText)
                    }
                    .buttonStyle(MyGridPressableLinkStyle())
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
    }

    private var listMode: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, listing in
                    NavigationLink {
                        ListingCloudDetailView(listing: listing)
                    } label: {
                        MyListingsListRowWithDivider(
                            listing: listing,
                            miseText: miseText,
                            showDivider: idx != filtered.count - 1
                        )
                    }
                    .buttonStyle(MyListPressableLinkStyle())
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
    }

    fileprivate func miseText(_ count: Int) -> String {
        return count <= 1 ? "\(count) mise" : "\(count) mises"
    }

    // MARK: - Refresh UX

    private func refreshTapped() {
        Haptic.light()
        toast = Toast(style: .info, title: "Actualisation…", systemImage: "arrow.clockwise")

        isRefreshing = true
        startListening(forceRestart: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            isRefreshing = false
            toast = Toast(style: .success, title: "À jour", systemImage: "checkmark.circle.fill")
        }
    }

    // MARK: - Firestore (mes annonces = mes ventes)

    private func startListening(forceRestart: Bool = false) {
        guard let uid = session.user?.uid else { return }
        if listener != nil && !forceRestart { return }
        stopListening()
        errorText = nil

        listener = repo.listenMySales(
            sellerId: uid,
            limit: 200,
            onUpdate: { self.listings = $0 },
            onError: { err in
                self.errorText = err.localizedDescription
                self.toast = Toast(style: .error, title: "Erreur de chargement", systemImage: "exclamationmark.triangle.fill", duration: 2.6)
                Haptic.error()
            }
        )
    }

    private func stopListening() {
        listener?.remove()
        listener = nil
    }
}

//
// MARK: - GRID CARD (local à MyListingsHubView)
//

private struct MyListingsGridCardDense: View {
    let listing: ListingCloud
    let miseText: (Int) -> String

    private let endingSoonThreshold: TimeInterval = 24 * 60 * 60

    private var isEndingSoon: Bool {
        guard listing.type == "auction" else { return false }
        guard listing.status == "active" else { return false }
        guard let end = listing.endDate else { return false }
        let remaining = end.timeIntervalSinceNow
        return remaining > 0 && remaining <= endingSoonThreshold
    }

    private var priceLine: String {
        if listing.type == "fixedPrice" {
            let p = listing.buyNowPriceCAD ?? 0
            return p > 0 ? String(format: "%.0f $ CAD", p) : "Prix non défini"
        } else {
            let current = listing.currentBidCAD ?? listing.startingBidCAD ?? 0
            return String(format: "Mise: %.0f $ • %@", current, miseText(listing.bidCount))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            ZStack(alignment: .topTrailing) {
                MyListingsThumb(urlString: listing.imageUrl, height: 190)

                VStack(alignment: .trailing, spacing: 6) {
                    if listing.shouldShowGradingBadge, let label = listing.gradingLabel {
                        GradingOverlayBadge(label: label, compact: false)
                    }

                    if let badge = listing.statusBadge, listing.status != "active" {
                        MyStatusChip(
                            text: badge.text,
                            systemImage: badge.icon,
                            color: badge.color,
                            backgroundOpacity: badge.backgroundOpacity,
                            strokeOpacity: badge.strokeOpacity,
                            isOverlayOnImage: true
                        )
                    }

                    if isEndingSoon {
                        MyEndingSoonBadgeOverlay(compact: false)
                    }
                }
                .padding(.top, 8)
                .padding(.trailing, 8)
            }

            Text(listing.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            Text(priceLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if listing.type == "auction", let end = listing.endDate {
                Text("Fin: \(end.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let u = listing.sellerUsername, !u.isEmpty {
                Text("@\(u)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ListingBadgeView(
                text: listing.typeBadge.text,
                systemImage: listing.typeBadge.icon,
                color: listing.typeBadge.color
            )
            .scaleEffect(0.95, anchor: .leading)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

private struct MyListingsListRowWithDivider: View {
    let listing: ListingCloud
    let miseText: (Int) -> String
    let showDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            MyListingsListRowCompact(listing: listing, miseText: miseText)

            if showDivider {
                Divider()
                    .padding(.leading, 66 + 12 + 4)
                    .opacity(0.5)
            }
        }
    }
}

private struct MyListingsListRowCompact: View {
    let listing: ListingCloud
    let miseText: (Int) -> String

    private let endingSoonThreshold: TimeInterval = 24 * 60 * 60

    private var isEndingSoon: Bool {
        guard listing.type == "auction" else { return false }
        guard listing.status == "active" else { return false }
        guard let end = listing.endDate else { return false }
        let remaining = end.timeIntervalSinceNow
        return remaining > 0 && remaining <= endingSoonThreshold
    }

    private var priceLine: String {
        if listing.type == "fixedPrice" {
            let p = listing.buyNowPriceCAD ?? 0
            return p > 0 ? String(format: "%.0f $ CAD", p) : "Prix non défini"
        } else {
            let current = listing.currentBidCAD ?? listing.startingBidCAD ?? 0
            return String(format: "Mise: %.0f $ CAD • %@", current, miseText(listing.bidCount))
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {

            ZStack(alignment: .topTrailing) {
                MyListingsThumb(urlString: listing.imageUrl, size: CGSize(width: 66, height: 92))

                if listing.shouldShowGradingBadge, let label = listing.gradingLabel {
                    GradingOverlayBadge(label: label, compact: true)
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                }
            }

            VStack(alignment: .leading, spacing: 4) {

                Text(listing.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    ListingBadgeView(
                        text: listing.typeBadge.text,
                        systemImage: listing.typeBadge.icon,
                        color: listing.typeBadge.color
                    )

                    if isEndingSoon {
                        MyEndingSoonChipInline()
                    }

                    if let badge = listing.statusBadge, listing.status != "active" {
                        MyStatusChip(
                            text: badge.text,
                            systemImage: badge.icon,
                            color: badge.color,
                            backgroundOpacity: badge.backgroundOpacity,
                            strokeOpacity: badge.strokeOpacity,
                            isOverlayOnImage: false
                        )
                    }

                    Spacer(minLength: 0)
                }

                Text(priceLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if listing.type == "auction", let end = listing.endDate {
                    Text("Fin: \(end.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let u = listing.sellerUsername, !u.isEmpty {
                    Text("@\(u)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct MyListingsThumb: View {
    let urlString: String?
    var size: CGSize? = nil
    var height: CGFloat? = nil

    init(urlString: String?, size: CGSize) {
        self.urlString = urlString
        self.size = size
        self.height = nil
    }

    init(urlString: String?, height: CGFloat) {
        self.urlString = urlString
        self.size = nil
        self.height = height
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))

            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                            .clipped()
                    case .failure:
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    default:
                        ProgressView()
                    }
                }
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 1)
        }
        .frame(width: size?.width, height: size?.height ?? height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MyEndingSoonBadgeOverlay: View {
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.fill")
                .font(.caption2)
            Text("Se termine bientôt")
                .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 5 : 6)
        .background(
            Capsule().fill(Color(.systemBackground).opacity(0.92))
        )
        .overlay(
            Capsule().stroke(Color.orange.opacity(0.75), lineWidth: 1)
        )
        .foregroundStyle(Color.orange)
        .shadow(color: Color.black.opacity(0.10), radius: 2, x: 0, y: 1)
    }
}

private struct MyEndingSoonChipInline: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock")
                .font(.caption2.weight(.semibold))
            Text("Bientôt")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.orange.opacity(0.12)))
        .overlay(Capsule().stroke(Color.orange.opacity(0.30), lineWidth: 1))
    }
}

private struct MyListPressableLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? Color.blue.opacity(0.08) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .opacity(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: configuration.isPressed)
    }
}

private struct MyGridPressableLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .opacity(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: configuration.isPressed)
    }
}
