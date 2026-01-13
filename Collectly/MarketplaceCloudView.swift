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

    @AppStorage("marketplaceViewMode") private var viewModeRaw: String = ViewMode.grid.rawValue
    private var viewMode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .grid }

    enum ViewMode: String { case list, grid }

    enum MarketFilter: String, CaseIterable, Identifiable {
        case all = "Tous"
        case auctions = "Encans"
        case fixed = "Acheter maintenant"
        var id: String { rawValue }
    }

    // ✅ Uniformité : réglage unique pour le badge en mode GRILLE
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
                    } else if filteredListings.isEmpty {
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
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - GRID MODE

    private var gridModeDense: some View {
        GeometryReader { geo in
            let cols = denseColumns(for: geo.size.width)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {

                    if !auctions.isEmpty {
                        sectionHeader(title: "Encans", count: auctions.count, icon: "hammer.fill")

                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(auctions) { listing in
                                NavigationLink {
                                    ListingCloudDetailView(listing: listing)
                                } label: {
                                    MarketplaceGridCardDense(listing: listing, badgeOffset: gridBadgeOffset)
                                }
                                .buttonStyle(GridPressableLinkStyle())
                            }
                        }
                    }

                    if !fixedPrice.isEmpty {
                        sectionHeader(title: "Acheter maintenant", count: fixedPrice.count, icon: "tag.fill")

                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(fixedPrice) { listing in
                                NavigationLink {
                                    ListingCloudDetailView(listing: listing)
                                } label: {
                                    MarketplaceGridCardDense(listing: listing, badgeOffset: gridBadgeOffset)
                                }
                                .buttonStyle(GridPressableLinkStyle())
                            }
                        }
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

    // MARK: - LIST MODE (✅ inchangé)

    private var listMode: some View {
        ScrollView {
            LazyVStack(spacing: 10) {

                if !auctions.isEmpty {
                    sectionHeader(title: "Encans", count: auctions.count, icon: "hammer.fill")
                    ForEach(auctions) { listing in
                        NavigationLink {
                            ListingCloudDetailView(listing: listing)
                        } label: {
                            MarketplaceListRow(listing: listing)
                        }
                        .buttonStyle(ListPressableLinkStyle())
                    }
                }

                if !fixedPrice.isEmpty {
                    sectionHeader(title: "Acheter maintenant", count: fixedPrice.count, icon: "tag.fill")
                    ForEach(fixedPrice) { listing in
                        NavigationLink {
                            ListingCloudDetailView(listing: listing)
                        } label: {
                            MarketplaceListRow(listing: listing)
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

    // MARK: - Filtering

    private var filteredListings: [ListingCloud] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return listings
            .filter { $0.status == "active" }
            .filter { l in
                switch filter {
                case .all: return true
                case .auctions: return l.type != "fixedPrice"
                case .fixed: return l.type == "fixedPrice"
                }
            }
            .filter { l in
                guard !q.isEmpty else { return true }
                let hay = (l.title + " " + (l.descriptionText ?? "")).lowercased()
                return hay.contains(q)
            }
            .sorted { a, b in
                if a.type != b.type { return a.type != "fixedPrice" }
                return a.createdAt > b.createdAt
            }
    }

    private var auctions: [ListingCloud] { filteredListings.filter { $0.type != "fixedPrice" } }
    private var fixedPrice: [ListingCloud] { filteredListings.filter { $0.type == "fixedPrice" } }

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
}

//
// MARK: - LIST ROW (✅ inchangé)
//

private struct MarketplaceListRow: View {
    let listing: ListingCloud

    var body: some View {
        HStack(spacing: 12) {

            ZStack(alignment: .topTrailing) {
                MarketplaceSlabThumb(urlString: listing.imageUrl, size: CGSize(width: 78, height: 112))

                if listing.shouldShowGradingBadge, let label = listing.gradingLabel {
                    GradingOverlayBadge(label: label, compact: true)
                        .offset(x: 8, y: -8)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(listing.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                ListingBadgeView(
                    text: listing.typeBadge.text,
                    systemImage: listing.typeBadge.icon,
                    color: listing.typeBadge.color
                )

                if listing.type == "fixedPrice" {
                    if let p = listing.buyNowPriceCAD {
                        Text(String(format: "%.0f $ CAD", p))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Prix non défini")
                            .foregroundStyle(.secondary)
                    }

                    if let u = listing.sellerUsername, !u.isEmpty {
                        Text("@\(u)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    let current = listing.currentBidCAD ?? listing.startingBidCAD ?? 0
                    Text(String(format: "Mise: %.0f $ CAD • %d mises", current, listing.bidCount))
                        .foregroundStyle(.secondary)

                    if let end = listing.endDate {
                        Text("Se termine le \(end.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let u = listing.sellerUsername, !u.isEmpty {
                        Text("@\(u)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

//
// MARK: - GRID CARD (✅ corrigé: badge rentré bas/gauche)
//

private struct MarketplaceGridCardDense: View {
    let listing: ListingCloud
    let badgeOffset: CGSize

    var body: some View {
        ZStack(alignment: .topTrailing) {

            VStack(alignment: .leading, spacing: 6) {

                MarketplaceSlabThumb(urlString: listing.imageUrl, size: CGSize(width: 999, height: 190))
                    .frame(height: 190)

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
                    Text(String(format: "Mise: %.0f $ • %d", current, listing.bidCount))
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

            if listing.shouldShowGradingBadge, let label = listing.gradingLabel {
                GradingOverlayBadge(label: label, compact: false)
                    .offset(badgeOffset) // ✅ (-4, +6)
            }
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
