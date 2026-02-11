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

    // ✅ Micro-UX
    @State private var isRefreshing: Bool = false
    @State private var toast: Toast? = nil

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
                .onChangeUX(of: tab) { Haptic.light() }

                // Sub-filters
                HStack(spacing: 10) {
                    if tab == .bids {
                        Picker("", selection: $bidsFilter) {
                            ForEach(BidsFilter.allCases) { f in
                                Text(f.rawValue).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChangeUX(of: bidsFilter) { Haptic.light() }
                    } else {
                        Picker("", selection: $salesFilter) {
                            ForEach(SalesFilter.allCases) { f in
                                Text(f.rawValue).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChangeUX(of: salesFilter) { Haptic.light() }
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
                            LazyVStack(spacing: 0) {
                                ForEach(Array(currentList.enumerated()), id: \.element.id) { idx, listing in
                                    NavigationLink {
                                        ListingCloudDetailView(listing: listing)
                                    } label: {
                                        VStack(spacing: 0) {
                                            MyDealsRow(
                                                listing: listing,
                                                endingSoonThreshold: endingSoonThreshold
                                            )

                                            // ✅ Divider aligné après la vignette
                                            if idx != currentList.count - 1 {
                                                Divider()
                                                    .padding(.leading, 12 + 78 + 12)
                                            }
                                        }
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
                    Button { refreshTapped() } label: {
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
            .onAppear {
                tab = initialTab
                startListening()
            }
            .onDisappear { stopListening() }
        }
        .toast($toast)
    }

    // MARK: - Micro-UX refresh

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
            // ✅ Mes enchères (MVP): auctions où tu es lastBidderId (filtré côté repo)
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
                // tri: le plus récent d'abord (soldAt/endedAt si dispo)
                list.sort { a, b in
                    let ta = a.soldAt ?? a.endedAt ?? a.updatedAt ?? a.createdAt
                    let tb = b.soldAt ?? b.endedAt ?? b.updatedAt ?? b.createdAt
                    return ta > tb
                }
            }

        } else {
            // ✅ Mes ventes: basé sur status
            switch salesFilter {

            case .active:
                list = list.filter { $0.status == "active" || $0.status == "paused" }

                // tri: encans fin bientôt en premier, sinon récents
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
                list.sort { a, b in
                    let ta = a.soldAt ?? a.updatedAt ?? a.createdAt
                    let tb = b.soldAt ?? b.updatedAt ?? b.createdAt
                    return ta > tb
                }

            case .ended:
                list = list.filter { $0.status == "ended" }
                list.sort { a, b in
                    let ta = a.endedAt ?? a.updatedAt ?? a.createdAt
                    let tb = b.endedAt ?? b.updatedAt ?? b.createdAt
                    return ta > tb
                }
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
            onError: { err in
                self.errorText = err.localizedDescription
                self.toast = Toast(style: .error, title: "Erreur de chargement", systemImage: "exclamationmark.triangle.fill", duration: 2.6)
                Haptic.error()
            }
        )

        bidsListener = repo.listenMyBidListings(
            bidderId: userId,
            limit: 200,
            onUpdate: { self.myBidListings = $0 },
            onError: { err in
                self.errorText = err.localizedDescription
                self.toast = Toast(style: .error, title: "Erreur de chargement", systemImage: "exclamationmark.triangle.fill", duration: 2.6)
                Haptic.error()
            }
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
        if listing.status == "sold" {
            let p = listing.finalPriceCAD
                ?? listing.currentBidCAD
                ?? listing.buyNowPriceCAD
                ?? 0
            return String(format: "Vendu • %.0f $ CAD", p)
        }

        if listing.type == "fixedPrice" {
            if let p = listing.buyNowPriceCAD {
                return String(format: "%.0f $ CAD", p)
            }
            return "Prix non défini"
        } else {
            let current = listing.currentBidCAD ?? listing.startingBidCAD ?? 0
            let countText = (listing.bidCount <= 1 ? "\(listing.bidCount) mise" : "\(listing.bidCount) mises")
            return String(format: "Mise: %.0f $ CAD • %@", current, countText)
        }
    }

    private var subLine: String? {
        if listing.status == "sold" {
            let buyer = (listing.buyerUsername ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let who = buyer.isEmpty ? nil : "@\(buyer)"
            let date = listing.soldAt

            if let who, let date {
                return "\(who) • \(date.formatted(date: .abbreviated, time: .shortened))"
            }
            if let who { return who }
            if let date { return date.formatted(date: .abbreviated, time: .shortened) }
            return nil
        }

        if listing.status == "ended" {
            if let date = listing.endedAt {
                return "Terminée • \(date.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Terminée"
        }

        if listing.type == "auction", let end = listing.endDate, listing.status == "active" {
            return "Se termine \(end.formatted(date: .abbreviated, time: .shortened))"
        }

        return nil
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
                }
                .padding(.top, 6)
                .padding(.trailing, 6)
                .zIndex(10)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(listing.title)
                    .font(.headline)
                    .lineLimit(2)

                // ✅ Même ligne: Type + Se termine bientôt + Statut (vendue/terminée/pause)
                HStack(spacing: 8) {
                    ListingBadgeView(
                        text: listing.typeBadge.text,
                        systemImage: listing.typeBadge.icon,
                        color: listing.typeBadge.color
                    )

                    if isEndingSoon {
                        EndingSoonChipInline()
                    }

                    // ✅ Statut: MyStatusChip (opacités)
                    if let s = listing.statusBadge, listing.status != "active" {
                        MyStatusChip(
                            text: s.text,
                            systemImage: s.icon,
                            color: s.color,
                            backgroundOpacity: s.backgroundOpacity,
                            strokeOpacity: s.strokeOpacity,
                            isOverlayOnImage: false
                        )
                    }

                    Spacer(minLength: 0)
                }

                Text(priceLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let subLine {
                    Text(subLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if listing.status == "active", listing.type == "auction", let end = listing.endDate {
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
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// ✅ Chip “Se termine bientôt” compact sur la même ligne que “Encan”
private struct EndingSoonChipInline: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.fill")
                .font(.caption2)
            Text("Se termine bientôt")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color(.systemBackground).opacity(0.92))
        )
        .overlay(
            Capsule()
                .stroke(Color.orange.opacity(0.75), lineWidth: 1)
        )
        .foregroundStyle(Color.orange)
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
                Text("Reste \(formatRemaining(remaining))")
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

// MARK: - iOS17 onChange compat (no warnings)

private extension View {

    @ViewBuilder
    func onChangeUX<V: Equatable>(of value: V, _ action: @escaping () -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value) { _, _ in
                action()
            }
        } else {
            self._onChangeUXDeprecated(of: value, action)
        }
    }

    @available(iOS, introduced: 14.0, deprecated: 17.0)
    private func _onChangeUXDeprecated<V: Equatable>(of value: V, _ action: @escaping () -> Void) -> some View {
        self.onChange(of: value) { _ in
            action()
        }
    }
}

