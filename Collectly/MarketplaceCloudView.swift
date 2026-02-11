//
//  MarketplaceCloudView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import FirebaseFirestore

struct MarketplaceCloudView: View {

    private let repo = MarketplaceRepository()

    @State private var listener: ListenerRegistration?
    @State private var listings: [ListingCloud] = []
    @State private var errorText: String?

    @State private var query: String = ""
    @State private var filter: MarketFilter = .all

    // ✅ Tri
    @AppStorage("marketplaceSortMode") private var sortRaw: String = SortMode.defaultSoonestFirst.rawValue
    private var sortMode: SortMode { SortMode(rawValue: sortRaw) ?? .defaultSoonestFirst }

    @AppStorage("marketplaceViewMode") private var viewModeRaw: String = ViewMode.grid.rawValue
    private var viewMode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .grid }

    enum ViewMode: String { case list, grid }

    enum MarketFilter: String, CaseIterable, Identifiable {
        case all = "Tous"
        case auctions = "Encans"
        case fixed = "Acheter maintenant"
        var id: String { rawValue }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case defaultSoonestFirst = "Par défaut (fin bientôt d’abord)"
        case newest = "Plus récents"
        case priceLow = "Prix / mise: ↑"
        case priceHigh = "Prix / mise: ↓"
        case endingSoon = "Fin bientôt (encans)"
        var id: String { rawValue }
    }

    private let gridBadgeOffset = CGSize(width: -4, height: 6)

    var body: some View {
        NavigationStack {
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
                    } else if sortedFilteredListings.isEmpty {
                        ContentUnavailableView(
                            "Aucune annonce",
                            systemImage: "tag",
                            description: Text("Aucune annonce active pour le moment.")
                        )
                    } else {
                        if viewMode == .grid {
                            gridModeDense
                        } else {
                            listMode
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Marketplace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {

                    Menu {
                        ForEach(SortMode.allCases) { m in
                            Button {
                                sortRaw = m.rawValue
                            } label: {
                                if sortMode == m {
                                    Label(m.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(m.rawValue)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }

                    Button {
                        viewModeRaw = (viewMode == .grid) ? ViewMode.list.rawValue : ViewMode.grid.rawValue
                    } label: {
                        Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                    }

                    Button { startListening(forceRestart: true) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear { startListening() }
            .onDisappear { stopListening() }
        }
    }

    // MARK: - Top controls

    private var topControls: some View {
        VStack(spacing: 6) {
            Picker("Filtre", selection: $filter) {
                ForEach(MarketFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Rechercher…", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !query.isEmpty {
                    Button { query = "" } label: {
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

    // MARK: - GRID MODE

    private var gridModeDense: some View {
        GeometryReader { geo in
            let cols = denseColumns(for: geo.size.width)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {

                    if filter == .all {
                        let a = sortedAuctions
                        let f = sortedFixedPrice

                        if !a.isEmpty {
                            sectionHeader(title: "Encans", count: a.count, icon: "hammer.fill")
                            LazyVGrid(columns: cols, spacing: 10) {
                                ForEach(a) { listing in
                                    NavigationLink {
                                        ListingCloudDetailView(listing: listing)
                                    } label: {
                                        MarketplaceGridCardDense(
                                            listing: listing,
                                            badgeOffset: gridBadgeOffset,
                                            miseText: miseText
                                        )
                                    }
                                    .buttonStyle(GridPressableLinkStyle())
                                }
                            }
                        }

                        if !f.isEmpty {
                            sectionHeader(title: "Acheter maintenant", count: f.count, icon: "tag.fill")
                            LazyVGrid(columns: cols, spacing: 10) {
                                ForEach(f) { listing in
                                    NavigationLink {
                                        ListingCloudDetailView(listing: listing)
                                    } label: {
                                        MarketplaceGridCardDense(
                                            listing: listing,
                                            badgeOffset: gridBadgeOffset,
                                            miseText: miseText
                                        )
                                    }
                                    .buttonStyle(GridPressableLinkStyle())
                                }
                            }
                        }

                    } else {
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(sortedFilteredListings) { listing in
                                NavigationLink {
                                    ListingCloudDetailView(listing: listing)
                                } label: {
                                    MarketplaceGridCardDense(
                                        listing: listing,
                                        badgeOffset: gridBadgeOffset,
                                        miseText: miseText
                                    )
                                }
                                .buttonStyle(GridPressableLinkStyle())
                            }
                        }
                        .padding(.top, 4)
                    }

                    Spacer(minLength: 10)
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
            }
        }
    }

    private func denseColumns(for width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = 10
        let isWide = width >= 420
        let count = isWide ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    // MARK: - LIST MODE (✅ séparateurs)

    private var listMode: some View {
        ScrollView {
            LazyVStack(spacing: 0) { // ✅ 0, car Divider gère la séparation

                if filter == .all {
                    let a = sortedAuctions
                    let f = sortedFixedPrice

                    if !a.isEmpty {
                        sectionHeader(title: "Encans", count: a.count, icon: "hammer.fill")
                            .padding(.bottom, 4)

                        ForEach(Array(a.enumerated()), id: \.element.id) { idx, listing in
                            NavigationLink {
                                ListingCloudDetailView(listing: listing)
                            } label: {
                                MarketplaceListRowWithDivider(
                                    listing: listing,
                                    miseText: miseText,
                                    showDivider: idx != a.count - 1
                                )
                            }
                            .buttonStyle(ListPressableLinkStyle())
                        }

                        if !f.isEmpty {
                            // petite séparation entre sections
                            Divider()
                                .padding(.vertical, 8)
                                .padding(.leading, 12)
                        }
                    }

                    if !f.isEmpty {
                        sectionHeader(title: "Acheter maintenant", count: f.count, icon: "tag.fill")
                            .padding(.bottom, 4)

                        ForEach(Array(f.enumerated()), id: \.element.id) { idx, listing in
                            NavigationLink {
                                ListingCloudDetailView(listing: listing)
                            } label: {
                                MarketplaceListRowWithDivider(
                                    listing: listing,
                                    miseText: miseText,
                                    showDivider: idx != f.count - 1
                                )
                            }
                            .buttonStyle(ListPressableLinkStyle())
                        }
                    }

                } else {
                    let list = sortedFilteredListings
                    ForEach(Array(list.enumerated()), id: \.element.id) { idx, listing in
                        NavigationLink {
                            ListingCloudDetailView(listing: listing)
                        } label: {
                            MarketplaceListRowWithDivider(
                                listing: listing,
                                miseText: miseText,
                                showDivider: idx != list.count - 1
                            )
                        }
                        .buttonStyle(ListPressableLinkStyle())
                    }
                }

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
    }

    private func sectionHeader(title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title).font(.headline)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    // MARK: - Filtering + Sorting

    private var baseFiltered: [ListingCloud] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return listings
            .filter { $0.status == "active" }
            .filter { l in
                switch filter {
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
    }

    private var sortedFilteredListings: [ListingCloud] {
        sort(list: baseFiltered, mode: sortMode)
    }

    private var sortedAuctions: [ListingCloud] {
        sort(list: baseFiltered.filter { $0.type == "auction" }, mode: sortMode)
    }

    private var sortedFixedPrice: [ListingCloud] {
        sort(list: baseFiltered.filter { $0.type == "fixedPrice" }, mode: sortMode)
    }

    private func sort(list: [ListingCloud], mode: SortMode) -> [ListingCloud] {
        switch mode {

        case .defaultSoonestFirst:
            return list.sorted { a, b in
                if a.type != b.type { return a.type == "auction" }

                if a.type == "auction" && b.type == "auction" {
                    let da = a.endDate ?? .distantFuture
                    let db = b.endDate ?? .distantFuture
                    if da != db { return da < db }
                    return a.createdAt > b.createdAt
                }

                return a.createdAt > b.createdAt
            }

        case .endingSoon:
            return list.sorted { a, b in
                let aIsAuction = (a.type == "auction")
                let bIsAuction = (b.type == "auction")
                if aIsAuction != bIsAuction { return aIsAuction }

                if aIsAuction && bIsAuction {
                    let da = a.endDate ?? .distantFuture
                    let db = b.endDate ?? .distantFuture
                    if da != db { return da < db }
                    return a.createdAt > b.createdAt
                }

                return a.createdAt > b.createdAt
            }

        case .newest:
            return list.sorted { $0.createdAt > $1.createdAt }

        case .priceLow:
            return list.sorted { a, b in
                let pa = priceValue(for: a)
                let pb = priceValue(for: b)
                if pa != pb { return pa < pb }
                return a.createdAt > b.createdAt
            }

        case .priceHigh:
            return list.sorted { a, b in
                let pa = priceValue(for: a)
                let pb = priceValue(for: b)
                if pa != pb { return pa > pb }
                return a.createdAt > b.createdAt
            }
        }
    }

    private func priceValue(for listing: ListingCloud) -> Double {
        if listing.type == "fixedPrice" {
            return listing.buyNowPriceCAD ?? 0
        } else {
            return listing.currentBidCAD ?? listing.startingBidCAD ?? 0
        }
    }

    // MARK: - Firestore

    private func startListening(forceRestart: Bool = false) {
        if listener != nil && !forceRestart { return }
        stopListening()

        errorText = nil
        listener = repo.listenPublicActiveListings(
            limit: 200,
            onUpdate: { self.listings = $0 },
            onError: { self.errorText = $0.localizedDescription }
        )
    }

    private func stopListening() {
        listener?.remove()
        listener = nil
    }

    // MARK: - French pluralization (✅ 0 et 1 singulier)

    fileprivate func miseText(_ count: Int) -> String {
        return count <= 1 ? "\(count) mise" : "\(count) mises"
    }
}

//
// MARK: - LIST ROW (COMPACT)
//

private struct MarketplaceListRowCompact: View {
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
            if let p = listing.buyNowPriceCAD {
                return String(format: "%.0f $ CAD", p)
            }
            return "Prix non défini"
        } else {
            let current = listing.currentBidCAD ?? listing.startingBidCAD ?? 0
            return String(format: "Mise: %.0f $ CAD • %@",
                          current,
                          miseText(listing.bidCount))
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {

            ZStack(alignment: .topTrailing) {
                MarketplaceSlabThumb(urlString: listing.imageUrl, size: CGSize(width: 66, height: 92))
                    .zIndex(0)

                if listing.shouldShowGradingBadge, let label = listing.gradingLabel {
                    GradingOverlayBadge(label: label, compact: true)
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                        .zIndex(10)
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
                        EndingSoonChipInline()
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

//
// MARK: - LIST ROW + DIVIDER
//

private struct MarketplaceListRowWithDivider: View {
    let listing: ListingCloud
    let miseText: (Int) -> String
    let showDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            MarketplaceListRowCompact(listing: listing, miseText: miseText)

            if showDivider {
                Divider()
                    .padding(.leading, 66 + 12 + 4) // thumb + spacing + petite marge => divider alignée au texte
                    .opacity(0.5)
            }
        }
    }
}

//
// MARK: - GRID CARD
//

private struct MarketplaceGridCardDense: View {
    let listing: ListingCloud
    let badgeOffset: CGSize
    let miseText: (Int) -> String

    private let endingSoonThreshold: TimeInterval = 24 * 60 * 60

    private var isEndingSoon: Bool {
        guard listing.type == "auction" else { return false }
        guard listing.status == "active" else { return false }
        guard let end = listing.endDate else { return false }
        let remaining = end.timeIntervalSinceNow
        return remaining > 0 && remaining <= endingSoonThreshold
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {

                ZStack(alignment: .topTrailing) {
                    MarketplaceSlabThumb(urlString: listing.imageUrl, size: CGSize(width: 999, height: 190))
                        .frame(height: 190)
                        .zIndex(0)

                    VStack(alignment: .trailing, spacing: 6) {
                        if listing.shouldShowGradingBadge, let label = listing.gradingLabel {
                            GradingOverlayBadge(label: label, compact: false)
                        }
                        if isEndingSoon {
                            EndingSoonBadgeOverlay(compact: false)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                    .zIndex(10)
                }

                Text(listing.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                if listing.type == "fixedPrice" {
                    if let p = listing.buyNowPriceCAD {
                        Text(String(format: "%.0f $ CAD", p))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Prix non défini")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let current = listing.currentBidCAD ?? listing.startingBidCAD ?? 0
                    Text(String(format: "Mise: %.0f $ • %@", current, miseText(listing.bidCount)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let end = listing.endDate {
                        Text("Fin: \(end.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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

                Spacer(minLength: 0)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }
}

//
// MARK: - SLAB THUMB
//

private struct MarketplaceSlabThumb: View {
    let urlString: String?
    let size: CGSize

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
        .frame(width: size.width == 999 ? nil : size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

//
// MARK: - Ending Soon (Grid overlay + List inline chip)
//

private struct EndingSoonBadgeOverlay: View {
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
            Capsule()
                .fill(Color(.systemBackground).opacity(0.92))
        )
        .overlay(
            Capsule()
                .stroke(Color.orange.opacity(0.75), lineWidth: 1)
        )
        .foregroundStyle(Color.orange)
        .shadow(color: Color.black.opacity(0.10), radius: 2, x: 0, y: 1)
    }
}

private struct EndingSoonChipInline: View {
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
        .background(
            Capsule()
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            Capsule()
                .stroke(Color.orange.opacity(0.30), lineWidth: 1)
        )
    }
}

//
// MARK: - Pressable styles
//

private struct ListPressableLinkStyle: ButtonStyle {
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

private struct GridPressableLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .opacity(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: configuration.isPressed)
    }
}
