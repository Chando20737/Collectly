//
//  MyListingsView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct MyListingsView: View {

    @EnvironmentObject private var session: SessionStore

    private let repo = MarketplaceRepository()
    private let db = Firestore.firestore()

    @State private var listener: ListenerRegistration?
    @State private var listings: [ListingCloud] = []
    @State private var errorText: String?

    @State private var query: String = ""
    @State private var filter: ListingFilter = .all
    @State private var viewMode: ViewMode = .grid

    // ✅ Navigation programmée
    @State private var selectedListing: ListingCloud?

    // ✅ Dialogs / actions
    @State private var confirmEnd: ListingCloud?
    @State private var confirmDelete: ListingCloud?
    @State private var actionError: String?
    @State private var isWorking = false

    enum ViewMode: String, CaseIterable, Identifiable {
        case grid = "Grille"
        case list = "Liste"
        var id: String { rawValue }
    }

    enum ListingFilter: String, CaseIterable, Identifiable {
        case all = "Tous"
        case auctions = "Encans"
        case fixed = "Acheter maintenant"
        var id: String { rawValue }
    }

    // MARK: - Bindings (✅ évite l’erreur “unable to type-check”)

    private var confirmEndPresented: Binding<Bool> {
        Binding(
            get: { confirmEnd != nil },
            set: { newValue in if !newValue { confirmEnd = nil } }
        )
    }

    private var confirmDeletePresented: Binding<Bool> {
        Binding(
            get: { confirmDelete != nil },
            set: { newValue in if !newValue { confirmDelete = nil } }
        )
    }

    private var actionErrorPresented: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { newValue in if !newValue { actionError = nil } }
        )
    }

    // MARK: - FR plural (0 et 1 -> singulier)

    private func misesText(_ count: Int) -> String {
        return count <= 1 ? "\(count) mise" : "\(count) mises"
    }

    // MARK: - UI

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Mes annonces")
                .navigationDestination(item: $selectedListing) { listing in
                    ListingCloudDetailView(listing: listing)
                }
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .top) { topControls }
                .onAppear { startListening() }
                .onDisappear { stopListening() }
                .onChange(of: session.user?.uid) { _, _ in
                    startListening(forceRestart: true)
                }
                .confirmationDialog(
                    "Retirer l’annonce?",
                    isPresented: confirmEndPresented,
                    titleVisibility: .visible
                ) {
                    Button("Retirer maintenant", role: .destructive) {
                        guard let target = confirmEnd else { return }
                        Task { await endListingNow(target) }
                    }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    if let t = confirmEnd {
                        Text("L’annonce sera marquée « terminée » et ne sera plus visible dans Marketplace.\n\n• \(t.title)")
                    }
                }
                .confirmationDialog(
                    "Supprimer l’annonce?",
                    isPresented: confirmDeletePresented,
                    titleVisibility: .visible
                ) {
                    Button("Supprimer définitivement", role: .destructive) {
                        guard let target = confirmDelete else { return }
                        Task { await deleteListingNow(target) }
                    }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    if let t = confirmDelete {
                        Text("Cette action est irréversible.\n\n• \(t.title)")
                    }
                }
                .alert("Erreur", isPresented: actionErrorPresented) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(actionError ?? "")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.user == nil {
            ContentUnavailableView(
                "Connexion requise",
                systemImage: "person.crop.circle",
                description: Text("Connecte-toi pour voir tes annonces.")
            )
        } else if let errorText {
            ContentUnavailableView(
                "Erreur",
                systemImage: "exclamationmark.triangle",
                description: Text(errorText)
            )
        } else if filteredListings.isEmpty {
            ContentUnavailableView(
                "Aucune annonce",
                systemImage: "tray",
                description: Text(emptyMessage)
            )
        } else {
            if viewMode == .grid {
                myListingsGrid
            } else {
                myListingsList
            }
        }
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { startListening(forceRestart: true) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(session.user == nil)
        }
    }

    // MARK: - Top controls

    private var topControls: some View {
        VStack(spacing: 10) {

            Picker("Affichage", selection: $viewMode) {
                ForEach(ViewMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Picker("Filtre", selection: $filter) {
                ForEach(ListingFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Rechercher une annonce…", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Empty / filtering

    private var emptyMessage: String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty && filter == .all { return "Tu n’as aucune annonce pour le moment." }
        if q.isEmpty { return "Aucune annonce pour ce filtre." }
        return "Aucun résultat pour “\(q)”."
    }

    private var filteredListings: [ListingCloud] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return listings
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
                if a.type != b.type { return a.type != "fixedPrice" } // Encans avant fixedPrice
                return a.createdAt > b.createdAt
            }
    }

    private var auctions: [ListingCloud] { filteredListings.filter { $0.type != "fixedPrice" } }
    private var fixedPrice: [ListingCloud] { filteredListings.filter { $0.type == "fixedPrice" } }

    // MARK: - Grid

    private var myListingsGrid: some View {
        ScrollView {
            VStack(spacing: 14) {

                if !auctions.isEmpty {
                    gridSectionHeader(title: "Encans", count: auctions.count, icon: "hammer.fill")

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10, alignment: .top),
                            GridItem(.flexible(), spacing: 10, alignment: .top)
                        ],
                        spacing: 10
                    ) {
                        ForEach(auctions) { listing in
                            MyListingGridCard(
                                listing: listing,
                                isWorking: isWorking,
                                misesText: misesText,
                                onOpen: { selectedListing = listing },
                                onTogglePause: { Task { await togglePauseResume(listing) } },
                                onEnd: { confirmEnd = listing },
                                onDelete: { confirmDelete = listing }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                }

                if !fixedPrice.isEmpty {
                    gridSectionHeader(title: "Acheter maintenant", count: fixedPrice.count, icon: "tag.fill")

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10, alignment: .top),
                            GridItem(.flexible(), spacing: 10, alignment: .top)
                        ],
                        spacing: 10
                    ) {
                        ForEach(fixedPrice) { listing in
                            MyListingGridCard(
                                listing: listing,
                                isWorking: isWorking,
                                misesText: misesText,
                                onOpen: { selectedListing = listing },
                                onTogglePause: { Task { await togglePauseResume(listing) } },
                                onEnd: { confirmEnd = listing },
                                onDelete: { confirmDelete = listing }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
    }

    private func gridSectionHeader(title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .textCase(nil)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    // MARK: - List

    private var myListingsList: some View {
        List {
            if !auctions.isEmpty {
                Section(header: listSectionHeader(title: "Encans", count: auctions.count, icon: "hammer.fill")) {
                    ForEach(auctions) { listing in
                        MyListingListRow(
                            listing: listing,
                            isWorking: isWorking,
                            misesText: misesText,
                            onOpen: { selectedListing = listing },
                            onTogglePause: { Task { await togglePauseResume(listing) } },
                            onEnd: { confirmEnd = listing },
                            onDelete: { confirmDelete = listing }
                        )
                    }
                }
            }

            if !fixedPrice.isEmpty {
                Section(header: listSectionHeader(title: "Acheter maintenant", count: fixedPrice.count, icon: "tag.fill")) {
                    ForEach(fixedPrice) { listing in
                        MyListingListRow(
                            listing: listing,
                            isWorking: isWorking,
                            misesText: misesText,
                            onOpen: { selectedListing = listing },
                            onTogglePause: { Task { await togglePauseResume(listing) } },
                            onEnd: { confirmEnd = listing },
                            onDelete: { confirmDelete = listing }
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func listSectionHeader(title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .textCase(nil)
    }

    // MARK: - Firestore listening

    private func startListening(forceRestart: Bool = false) {
        guard let uid = session.user?.uid else {
            stopListening()
            listings = []
            errorText = nil
            return
        }

        if listener != nil && !forceRestart { return }
        stopListening()

        errorText = nil
        listener = repo.listenMyListings(uid: uid, limit: 200) { newItems in
            self.listings = newItems
        } onError: { err in
            self.errorText = err.localizedDescription
        }
    }

    private func stopListening() {
        listener?.remove()
        listener = nil
    }

    // MARK: - Rules (same logic as ListingCloudDetailView)

    private func canTogglePause(_ l: ListingCloud) -> Bool {
        if l.status == "sold" || l.status == "ended" { return false }
        if l.type == "auction" { return l.bidCount == 0 }
        return true
    }

    private func canEndNow(_ l: ListingCloud) -> Bool {
        if l.status == "sold" || l.status == "ended" { return false }

        if l.type == "fixedPrice" {
            return l.status == "active" || l.status == "paused"
        }
        if l.type == "auction" {
            return (l.status == "active" || l.status == "paused") && l.bidCount == 0
        }
        return false
    }

    private func canDeleteNow(_ l: ListingCloud) -> Bool {
        if l.status == "sold" { return false }
        if l.type == "auction" { return l.bidCount == 0 }
        return true
    }

    // MARK: - Actions

    private func togglePauseResume(_ l: ListingCloud) async {
        guard session.user != nil else { return }
        guard canTogglePause(l) else { return }
        if isWorking { return }

        await MainActor.run {
            actionError = nil
            isWorking = true
        }
        defer { Task { @MainActor in isWorking = false } }

        let ref = db.collection("listings").document(l.id)
        let nextStatus = (l.status == "paused") ? "active" : "paused"

        do {
            try await ref.updateData([
                "status": nextStatus,
                "updatedAt": Timestamp(date: Date())
            ])
        } catch {
            await MainActor.run { actionError = error.localizedDescription }
        }
    }

    private func endListingNow(_ l: ListingCloud) async {
        guard session.user != nil else { return }
        guard canEndNow(l) else { return }
        if isWorking { return }

        await MainActor.run {
            actionError = nil
            isWorking = true
            confirmEnd = nil
        }
        defer { Task { @MainActor in isWorking = false } }

        let ref = db.collection("listings").document(l.id)
        let now = Timestamp(date: Date())

        do {
            try await ref.updateData([
                "status": "ended",
                "endedAt": now,
                "updatedAt": now
            ])
        } catch {
            await MainActor.run { actionError = error.localizedDescription }
        }
    }

    private func deleteListingNow(_ l: ListingCloud) async {
        guard session.user != nil else { return }
        guard canDeleteNow(l) else { return }
        if isWorking { return }

        await MainActor.run {
            actionError = nil
            isWorking = true
            confirmDelete = nil
        }
        defer { Task { @MainActor in isWorking = false } }

        let ref = db.collection("listings").document(l.id)
        do {
            try await ref.delete()
        } catch {
            await MainActor.run { actionError = error.localizedDescription }
        }
    }
}

// MARK: - Grid card (Menu "..." top-left)

private struct MyListingGridCard: View {
    let listing: ListingCloud
    let isWorking: Bool
    let misesText: (Int) -> String

    let onOpen: () -> Void
    let onTogglePause: () -> Void
    let onEnd: () -> Void
    let onDelete: () -> Void

    private var isPaused: Bool { listing.status == "paused" }

    private var canTogglePause: Bool {
        if listing.status == "sold" || listing.status == "ended" { return false }
        if listing.type == "auction" { return listing.bidCount == 0 }
        return true
    }

    private var canEndNow: Bool {
        if listing.status == "sold" || listing.status == "ended" { return false }
        if listing.type == "fixedPrice" { return listing.status == "active" || listing.status == "paused" }
        if listing.type == "auction" { return (listing.status == "active" || listing.status == "paused") && listing.bidCount == 0 }
        return false
    }

    private var canDeleteNow: Bool {
        if listing.status == "sold" { return false }
        if listing.type == "auction" { return listing.bidCount == 0 }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            ZStack {
                ListingSlabThumb(urlString: listing.imageUrl, height: 200)
                    .opacity(isPaused ? 0.60 : 1.0)

                // Badge PSA/Grading en haut à droite
                if listing.shouldShowGradingBadge, let label = listing.gradingLabel {
                    VStack {
                        HStack {
                            Spacer()
                            GradingOverlayBadge(label: label, compact: false)
                                .offset(x: -4, y: 6)
                                .opacity(isPaused ? 0.75 : 1.0)
                                .padding(.trailing, 2)
                        }
                        Spacer()
                    }
                }

                // Menu "..." en haut à gauche
                VStack {
                    HStack {
                        Menu {
                            if canTogglePause {
                                Button {
                                    onTogglePause()
                                } label: {
                                    Label(
                                        listing.status == "paused" ? "Réactiver" : "Mettre en pause",
                                        systemImage: listing.status == "paused" ? "play.circle.fill" : "pause.circle.fill"
                                    )
                                }
                            }

                            if canEndNow {
                                Button(role: .destructive) {
                                    onEnd()
                                } label: {
                                    Label("Retirer l’annonce", systemImage: "xmark.circle")
                                }
                            }

                            if canDeleteNow {
                                Button(role: .destructive) {
                                    onDelete()
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(8)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                        }
                        .disabled(isWorking)
                        .padding(.leading, 6)
                        .padding(.top, 6)

                        Spacer()
                    }
                    Spacer()
                }
            }

            Text(listing.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(isPaused ? .secondary : .primary)

            HStack(spacing: 6) {
                ListingBadgeView(
                    text: listing.typeBadge.text,
                    systemImage: listing.typeBadge.icon,
                    color: listing.typeBadge.color
                )

                if let s = listing.statusBadge {
                    ListingBadgeView(
                        text: s.text,
                        systemImage: s.icon,
                        color: s.color
                    )
                }
            }
            .opacity(isPaused ? 0.70 : 1)

            if listing.type == "fixedPrice" {
                if let p = listing.buyNowPriceCAD {
                    Text(String(format: "%.0f $ CAD", p))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .opacity(isPaused ? 0.7 : 1)
                } else {
                    Text("Prix non défini")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .opacity(isPaused ? 0.7 : 1)
                }
            } else {
                let currentBid = listing.currentBidCAD ?? listing.startingBidCAD ?? 0
                let countText = misesText(listing.bidCount)

                Text(String(format: "Mise: %.0f $ CAD • %@", currentBid, countText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(isPaused ? 0.7 : 1)

                if let end = listing.endDate {
                    Text("Se termine le \(end.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .opacity(isPaused ? 0.7 : 1)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .opacity(isPaused ? 0.82 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }
}

// MARK: - List row

private struct MyListingListRow: View {
    let listing: ListingCloud
    let isWorking: Bool
    let misesText: (Int) -> String

    let onOpen: () -> Void
    let onTogglePause: () -> Void
    let onEnd: () -> Void
    let onDelete: () -> Void

    private var isPaused: Bool { listing.status == "paused" }

    private var canTogglePause: Bool {
        if listing.status == "sold" || listing.status == "ended" { return false }
        if listing.type == "auction" { return listing.bidCount == 0 }
        return true
    }

    private var canEndNow: Bool {
        if listing.status == "sold" || listing.status == "ended" { return false }
        if listing.type == "fixedPrice" { return listing.status == "active" || listing.status == "paused" }
        if listing.type == "auction" { return (listing.status == "active" || listing.status == "paused") && listing.bidCount == 0 }
        return false
    }

    private var canDeleteNow: Bool {
        if listing.status == "sold" { return false }
        if listing.type == "auction" { return listing.bidCount == 0 }
        return true
    }

    var body: some View {
        HStack(spacing: 12) {

            ZStack(alignment: .topTrailing) {
                ListingSlabThumb(urlString: listing.imageUrl, height: 78)
                    .frame(width: 56)
                    .opacity(isPaused ? 0.55 : 1.0)

                if listing.shouldShowGradingBadge, let label = listing.gradingLabel {
                    GradingOverlayBadge(label: label, compact: true)
                        .offset(x: 8, y: -8)
                        .opacity(isPaused ? 0.75 : 1.0)
                }
            }

            VStack(alignment: .leading, spacing: 6) {

                Text(listing.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(isPaused ? .secondary : .primary)

                HStack(spacing: 6) {
                    ListingBadgeView(
                        text: listing.typeBadge.text,
                        systemImage: listing.typeBadge.icon,
                        color: listing.typeBadge.color
                    )

                    if let status = listing.statusBadge {
                        ListingBadgeView(
                            text: status.text,
                            systemImage: status.icon,
                            color: status.color
                        )
                    }
                }
                .opacity(isPaused ? 0.7 : 1)

                if listing.type == "fixedPrice" {
                    if let p = listing.buyNowPriceCAD {
                        Text(String(format: "%.0f $ CAD", p))
                            .foregroundStyle(.secondary)
                            .opacity(isPaused ? 0.7 : 1)
                    } else {
                        Text("Prix non défini")
                            .foregroundStyle(.secondary)
                            .opacity(isPaused ? 0.7 : 1)
                    }
                } else {
                    let currentBid = listing.currentBidCAD ?? listing.startingBidCAD ?? 0
                    let countText = misesText(listing.bidCount)

                    Text(String(format: "Mise: %.0f $ CAD • %@", currentBid, countText))
                        .foregroundStyle(.secondary)
                        .opacity(isPaused ? 0.7 : 1)

                    if let end = listing.endDate {
                        Text("Se termine le \(end.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .opacity(isPaused ? 0.7 : 1)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .opacity(isPaused ? 0.80 : 1)
        .onTapGesture { onOpen() }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canTogglePause {
                Button { onTogglePause() } label: {
                    Label(listing.status == "paused" ? "Réactiver" : "Pause", systemImage: listing.status == "paused" ? "play.fill" : "pause.fill")
                }
                .tint(.blue)
                .disabled(isWorking)
            }

            if canEndNow {
                Button(role: .destructive) { onEnd() } label: {
                    Label("Retirer", systemImage: "xmark.circle")
                }
                .disabled(isWorking)
            }

            if canDeleteNow {
                Button(role: .destructive) { onDelete() } label: {
                    Label("Supprimer", systemImage: "trash")
                }
                .disabled(isWorking)
            }
        }
    }
}

// MARK: - Slab Thumb (remote)

private struct ListingSlabThumb: View {
    let urlString: String?
    let height: CGFloat

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
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failure:
                        placeholder
                    default:
                        ProgressView()
                    }
                }
            } else {
                placeholder
            }

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 1)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.secondary.opacity(0.10))
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
        .padding(6)
    }
}
