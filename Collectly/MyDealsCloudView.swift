//
//  MyDealsCloudView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-14.
//
import SwiftUI
import FirebaseFirestore

// ✅ Écran: Mes enchères / Mes ventes
struct MyDealsCloudView: View {

    private let repo = MarketplaceRepository()

    let userId: String
    let initialTab: Tab

    // ✅ Permet au Hub "Mes annonces" d’ouvrir directement Mes ventes ou Mes enchères
    init(userId: String, initialTab: Tab = .bids) {
        self.userId = userId
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab)
    }

    @State private var salesListener: ListenerRegistration?
    @State private var bidsListener: ListenerRegistration?

    @State private var mySales: [ListingCloud] = []
    @State private var myBidListings: [ListingCloud] = []

    @State private var errorText: String?

    @State private var tab: Tab = .bids

    @State private var bidsFilter: BidsFilter = .active
    @State private var salesFilter: SalesFilter = .active

    @State private var query: String = ""

    enum Tab: String, CaseIterable, Identifiable {
        case bids = "Mes enchères"
        case sales = "Mes ventes"
        var id: String { rawValue }
    }

    enum BidsFilter: String, CaseIterable, Identifiable {
        case active = "En cours"
        case ended = "Terminées"
        var id: String { rawValue }
    }

    enum SalesFilter: String, CaseIterable, Identifiable {
        case active = "Actives"
        case sold = "Vendues"
        case ended = "Terminées"
        var id: String { rawValue }
    }

    // ✅ Background compatible (iOS 14/15+)
    private var frostedBG: AnyShapeStyle {
        if #available(iOS 15.0, *) {
            return AnyShapeStyle(.ultraThinMaterial)
        } else {
            return AnyShapeStyle(Color(.secondarySystemBackground).opacity(0.95))
        }
    }

    private let endingSoonThreshold: TimeInterval = 24 * 60 * 60

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {

                // Tabs
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.top, 6)

                // Sub-filters
                HStack(spacing: 10) {
                    if tab == .bids {
                        Picker("", selection: $bidsFilter) {
                            ForEach(BidsFilter.allCases) { f in
                                Text(f.rawValue).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                    } else {
                        Picker("", selection: $salesFilter) {
                            ForEach(SalesFilter.allCases) { f in
                                Text(f.rawValue).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(.horizontal, 12)

                // Search
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
                .padding(.vertical, 8)
                .background(frostedBG)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 12)

                // Content
                Group {
                    if let errorText {
                        ContentUnavailableView(
                            "Erreur",
                            systemImage: "exclamationmark.triangle",
                            description: Text(errorText)
                        )
                    } else if currentList.isEmpty {
                        ContentUnavailableView(
                            tab == .bids ? "Aucune enchère" : "Aucune vente",
                            systemImage: tab == .bids ? "hammer" : "tag",
                            description: Text(tab == .bids
                                              ? "Aucune enchère correspondant à ce filtre."
                                              : "Aucune vente correspondant à ce filtre.")
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(currentList) { listing in
                                    NavigationLink {
                                        ListingCloudDetailView(listing: listing)
                                    } label: {
                                        MyDealsRow(
                                            listing: listing,
                                            endingSoonThreshold: endingSoonThreshold
                                        )
                                    }
                                    .buttonStyle(MyDealsPressableStyle())
                                }
                                Spacer(minLength: 12)
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(tab == .bids ? "Mes enchères" : "Mes ventes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { startListening(forceRestart: true) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                // ✅ S’assure qu’on ouvre le bon tab quand on arrive via le Hub
                tab = initialTab
                startListening()
            }
            .onDisappear { stopListening() }
        }
    }

    // MARK: - Filtering / Sorting

    private var currentList: [ListingCloud] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Date()

        var list: [ListingCloud] = (tab == .bids) ? myBidListings : mySales

        // Search
        if !q.isEmpty {
            list = list.filter { l in
                let hay = (l.title + " " + (l.descriptionText ?? "")).lowercased()
                return hay.contains(q)
            }
        }

        if tab == .bids {
            // ✅ Mes enchères (MVP): auctions où tu es lastBidderId
            list = list.filter { $0.type == "auction" }

            switch bidsFilter {
            case .active:
                list = list.filter { l in
                    guard l.status == "active" else { return false }
                    guard let end = l.endDate else { return true }
                    return end > now
                }
                // tri: fin bientôt
                list.sort { a, b in
                    let da = a.endDate ?? .distantFuture
                    let db = b.endDate ?? .distantFuture
                    if da != db { return da < db }
                    return a.createdAt > b.createdAt
                }

            case .ended:
                list = list.filter { l in
                    if l.status != "active" { return true }
                    if let end = l.endDate { return end <= now }
                    return false
                }
                list.sort { $0.createdAt > $1.createdAt }
            }

        } else {
            // ✅ Mes ventes: UNIQUEMENT basé sur status (logique pro)
            switch salesFilter {
            case .active:
                list = list.filter { $0.status == "active" || $0.status == "paused" }

                // tri: encans fin bientôt, sinon récents
                list.sort { a, b in
                    if a.type != b.type { return a.type == "auction" }
                    if a.type == "auction" && b.type == "auction" {
                        let da = a.endDate ?? .distantFuture
                        let db = b.endDate ?? .distantFuture
                        if da != db { return da < db }
                        return a.createdAt > b.createdAt
                    }
                    return a.createdAt > b.createdAt
                }

            case .sold:
                list = list.filter { $0.status == "sold" }
                list.sort { $0.createdAt > $1.createdAt }

            case .ended:
                list = list.filter { $0.status == "ended" }
                list.sort { $0.createdAt > $1.createdAt }
            }
        }

        return list
    }

    // MARK: - Firestore

    private func startListening(forceRestart: Bool = false) {
        if (salesListener != nil || bidsListener != nil), !forceRestart { return }
        stopListening()
        errorText = nil

        salesListener = repo.listenMySales(
            sellerId: userId,
            limit: 200,
            onUpdate: { self.mySales = $0 },
            onError: { self.errorText = $0.localizedDescription }
        )

        bidsListener = repo.listenMyBidListings(
            bidderId: userId,
            limit: 200,
            onUpdate: { self.myBidListings = $0 },
            onError: { self.errorText = $0.localizedDescription }
        )
    }

    private func stopListening() {
        salesListener?.remove()
        bidsListener?.remove()
        salesListener = nil
        bidsListener = nil
    }
}

// MARK: - Row

private struct MyDealsRow: View {

    let listing: ListingCloud
    let endingSoonThreshold: TimeInterval

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
                          (listing.bidCount <= 1 ? "\(listing.bidCount) mise" : "\(listing.bidCount) mises"))
        }
    }

    var body: some View {
        HStack(spacing: 12) {

            ZStack(alignment: .topTrailing) {
                MyDealsThumb(urlString: listing.imageUrl, size: CGSize(width: 78, height: 112))
                    .zIndex(0)

                VStack(alignment: .trailing, spacing: 6) {
                    if listing.shouldShowGradingBadge, let label = listing.gradingLabel {
                        GradingOverlayBadge(label: label, compact: true)
                    }
                    if isEndingSoon {
                        EndingSoonBadge(compact: true)
                    }
                }
                .padding(.top, 6)
                .padding(.trailing, 6)
                .zIndex(10)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(listing.title)
                    .font(.headline)
                    .lineLimit(2)

                ListingBadgeView(
                    text: listing.typeBadge.text,
                    systemImage: listing.typeBadge.icon,
                    color: listing.typeBadge.color
                )

                Text(priceLine)
                    .foregroundStyle(.secondary)

                if listing.type == "auction", let end = listing.endDate {
                    RemainingTimeText(endDate: end)
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

            Spacer()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Thumb

private struct MyDealsThumb: View {
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
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Remaining time (refresh léger 30s)

private struct RemainingTimeText: View {
    let endDate: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let remaining = endDate.timeIntervalSince(context.date)
            if remaining <= 0 {
                Text("Terminé")
            } else {
                Text("Se termine dans \(formatRemaining(remaining))")
            }
        }
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

// MARK: - Ending Soon Badge (opaque)

private struct EndingSoonBadge: View {
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

// MARK: - Pressable style

private struct MyDealsPressableStyle: ButtonStyle {
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
