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

    // ✅ Masquage local
    @AppStorage("myListings.hiddenIds") private var hiddenIdsRaw: String = ""   // "id1,id2,id3"
    @State private var showHiddenOnly: Bool = false

    // ✅ Popover “…” (près de la carte)
    @State private var popoverListing: ListingCloud? = nil
    @State private var showPopover: Bool = false

    enum ViewMode: String { case list, grid }

    enum TypeFilter: String, CaseIterable, Identifiable {
        case all = "Tous"
        case auctions = "Encans"
        case fixed = "Acheter maintenant"
        var id: String { rawValue }
    }

    private var leadingTitleWidth: CGFloat {
        max(220, UIScreen.main.bounds.width - 170)
    }

    // MARK: - Hidden ids helpers

    private var hiddenIds: Set<String> {
        Set(hiddenIdsRaw
            .split(separator: ",")
            .map { String($0) }
            .filter { !$0.isEmpty }
        )
    }

    private func setHiddenIds(_ ids: Set<String>) {
        hiddenIdsRaw = ids.sorted().joined(separator: ",")
    }

    private func isHidden(_ listing: ListingCloud) -> Bool {
        hiddenIds.contains(listing.id)
    }

    private func isListingActive(_ l: ListingCloud) -> Bool {
        if l.status != "active" { return false }
        if l.type == "auction", let end = l.endDate, end <= Date() { return false }
        return true
    }

    private func canHide(_ l: ListingCloud) -> Bool {
        return !isListingActive(l)
    }

    private func toggleHide(_ l: ListingCloud) {
        if !canHide(l) {
            toast = Toast(style: .info, title: "Annonce active — mets-la sur pause ou termine-la", systemImage: "info.circle")
            Haptic.error()
            return
        }

        var ids = hiddenIds
        if ids.contains(l.id) {
            ids.remove(l.id)
            setHiddenIds(ids)
            toast = Toast(style: .info, title: "Annonce réaffichée", systemImage: "eye")
        } else {
            ids.insert(l.id)
            setHiddenIds(ids)
            toast = Toast(style: .success, title: "Annonce masquée", systemImage: "eye.slash")
        }
        Haptic.light()
    }

    private func openPopover(for listing: ListingCloud) {
        Haptic.light()
        popoverListing = listing
        DispatchQueue.main.async {
            showPopover = true
        }
    }

    private func closePopover() {
        showPopover = false
        popoverListing = nil
    }

    // MARK: - Body

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
                                    showHiddenOnly ? "Aucune annonce masquée" : "Aucune annonce",
                                    systemImage: "tray.full",
                                    description: Text(showHiddenOnly ? "Tu n’as aucune annonce masquée." : "Aucune annonce correspondant à ce filtre.")
                                )
                            } else {
                                if viewMode == .grid { gridMode } else { listMode }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)

            .toolbar {

                ToolbarItem(placement: .topBarLeading) {
                    Text("Mes annonces")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: leadingTitleWidth, alignment: .leading)
                }

                // ✅ IMPORTANT:
                // - On GARDE le bouton cercle ellipsis.circle
                // - On N'AFFICHE PAS un autre "ellipsis" à côté
                ToolbarItemGroup(placement: .topBarTrailing) {

                    Menu {
                        Button {
                            Haptic.light()
                            showHiddenOnly.toggle()
                        } label: {
                            Label(
                                showHiddenOnly ? "Voir non masquées" : "Voir masquées",
                                systemImage: showHiddenOnly ? "eye" : "eye.slash"
                            )
                        }

                        if !hiddenIds.isEmpty {
                            Button(role: .destructive) {
                                Haptic.light()
                                setHiddenIds([])
                                toast = Toast(style: .success, title: "Tout réaffiché", systemImage: "eye")
                            } label: {
                                Label("Réafficher tout", systemImage: "eye")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Options")

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
            .onChange(of: typeFilter) { _, _ in Haptic.light() }

            HStack(spacing: 8) {

                Button {
                    Haptic.light()
                    showHiddenOnly.toggle()
                    toast = Toast(
                        style: .info,
                        title: showHiddenOnly ? "Masquées" : "Non masquées",
                        systemImage: showHiddenOnly ? "eye.slash" : "eye"
                    )
                } label: {
                    Image(systemName: showHiddenOnly ? "eye.slash.fill" : "eye")
                        .foregroundStyle(showHiddenOnly ? .primary : .secondary)
                }

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
                if showHiddenOnly { return hiddenIds.contains(l.id) }
                return !hiddenIds.contains(l.id)
            }
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
                    ZStack(alignment: .topLeading) {

                        NavigationLink {
                            ListingCloudDetailView(listing: listing)
                        } label: {
                            MyListingsGridCardDenseContent(listing: listing, miseText: miseText)
                        }
                        .buttonStyle(MyGridPressableLinkStyle())
                        .zIndex(0)

                        // ✅ “…” sur la carte (popover près de la carte)
                        EllipsisOverlayAnchorButton {
                            openPopover(for: listing)
                        }
                        .padding(.top, 8)     // ✅ même hauteur que le 1er badge à droite
                        .padding(.leading, 8)
                        .zIndex(10)
                        .popover(isPresented: Binding(
                            get: { showPopover && popoverListing?.id == listing.id },
                            set: { newValue in
                                if !newValue { closePopover() }
                            }
                        )) {
                            ListingPopoverSingleAction(
                                label: isHidden(listing) ? "Réafficher" : "Masquer",
                                systemImage: isHidden(listing) ? "eye" : "eye.slash",
                                enabled: canHide(listing),
                                disabledHint: "Annonce active — mets-la sur pause ou termine-la",
                                onTap: {
                                    toggleHide(listing)
                                    closePopover()
                                }
                            )
                            .presentationCompactAdaptation(.popover)
                        }
                    }
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
                    ZStack(alignment: .topTrailing) {

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
                        .zIndex(0)

                        // ✅ “…” sur la rangée (popover)
                        EllipsisOverlayAnchorButton {
                            openPopover(for: listing)
                        }
                        .padding(.top, 2)
                        .padding(.trailing, 2)
                        .zIndex(10)
                        .popover(isPresented: Binding(
                            get: { showPopover && popoverListing?.id == listing.id },
                            set: { newValue in
                                if !newValue { closePopover() }
                            }
                        )) {
                            ListingPopoverSingleAction(
                                label: isHidden(listing) ? "Réafficher" : "Masquer",
                                systemImage: isHidden(listing) ? "eye" : "eye.slash",
                                enabled: canHide(listing),
                                disabledHint: "Annonce active — mets-la sur pause ou termine-la",
                                onTap: {
                                    toggleHide(listing)
                                    closePopover()
                                }
                            )
                            .presentationCompactAdaptation(.popover)
                        }
                    }
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

    // MARK: - Firestore (mes annonces)

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

// MARK: - Popover single action (UX: seulement l’œil + “Masquer”)

private struct ListingPopoverSingleAction: View {

    let label: String
    let systemImage: String
    let enabled: Bool
    let disabledHint: String
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            Button {
                onTap()
            } label: {
                Label(label, systemImage: systemImage)
                    .font(.body.weight(.semibold))
            }
            .disabled(!enabled)

            if !enabled {
                Text(disabledHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 220)
    }
}

// MARK: - “…” overlay button (tap fiable au-dessus d’un NavigationLink)

private struct EllipsisOverlayAnchorButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .padding(8)
                .background(Circle().fill(Color(.systemBackground).opacity(0.92)))
                .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}

//
// MARK: - GRID CARD CONTENT
//

private struct MyListingsGridCardDenseContent: View {
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

            ZStack(alignment: .top) {
                MyListingsThumb(urlString: listing.imageUrl, height: 190)

                HStack(alignment: .top) {
                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 6) {

                        // ✅ Priorité “Terminée” avant PSA
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

                        if listing.shouldShowGradingBadge, let label = listing.gradingLabel {
                            GradingOverlayBadge(label: label, compact: false)
                        }

                        if isEndingSoon {
                            MyEndingSoonBadgeOverlay(compact: false)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 8)
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

                // ✅ Priorité “Terminée” avant PSA (sur l’image)
                VStack(alignment: .trailing, spacing: 6) {
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
                    if listing.shouldShowGradingBadge, let label = listing.gradingLabel {
                        GradingOverlayBadge(label: label, compact: true)
                    }
                }
                .padding(.top, 6)
                .padding(.trailing, 6)
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
        .background(Capsule().fill(Color(.systemBackground).opacity(0.92)))
        .overlay(Capsule().stroke(Color.orange.opacity(0.75), lineWidth: 1))
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
