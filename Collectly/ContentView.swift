//
//  ContentView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-15.
//
import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import FirebaseAuth
import FirebaseFirestore

// ✅ ContentView = wrapper (tab "Ma collection")
//    -> Affiche vide si pas connecté
//    -> Sinon, affiche la collection filtrée par ownerId (uid Firebase)
struct ContentView: View {

    @EnvironmentObject private var session: SessionStore

    var body: some View {
        NavigationStack {
            if let uid = session.user?.uid {
                CVCollectionHomeView(uid: uid)
            } else {
                ContentUnavailableView(
                    "Ma collection",
                    systemImage: "rectangle.stack",
                    description: Text("Connecte-toi pour voir ta collection.")
                )
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

// MARK: - Main collection view (ownerId filtered)

private struct CVCollectionHomeView: View {

    let uid: String

    @Environment(\.modelContext) private var modelContext

    // ✅ SwiftData: on filtre par ownerId via init(uid:)
    @Query private var cards: [CardItem]

    init(uid: String) {
        self.uid = uid
        _cards = Query(
            filter: #Predicate<CardItem> { $0.ownerId == uid },
            sort: [SortDescriptor(\CardItem.createdAt, order: .reverse)]
        )
    }

    // MARK: - Persisted UI state (UserDefaults)

    @AppStorage("collection.searchText") private var storedSearchText: String = ""
    @AppStorage("collection.viewMode") private var storedViewModeRaw: String = ViewMode.grid.rawValue
    @AppStorage("collection.sort") private var storedSortRaw: String = SortOption.newest.rawValue
    @AppStorage("collection.filter") private var storedFilterRaw: String = FilterOption.all.rawValue
    @AppStorage("collection.groupBy") private var storedGroupByRaw: String = GroupByOption.none.rawValue
    @AppStorage("collection.sectionSort") private var storedSectionSortRaw: String = SectionSortOption.valueHigh.rawValue

    // MARK: - UI state

    @State private var searchText: String = ""
    @State private var viewMode: ViewMode = .grid
    @State private var sort: SortOption = .newest
    @State private var filter: FilterOption = .all

    @State private var groupBy: GroupByOption = .none
    @State private var sectionSort: SectionSortOption = .valueHigh
    @State private var expandedSectionKeys: Set<String> = []

    @State private var uiErrorText: String? = nil

    // ✅ Sheets (Add manuel / Quick Edit)
    private enum SheetRoute: Identifiable, Equatable {
        case addManual
        case quickEdit(UUID) // id de la carte

        var id: String {
            switch self {
            case .addManual: return "addManual"
            case .quickEdit(let id): return "quickEdit-\(id.uuidString)"
            }
        }
    }

    @State private var sheet: SheetRoute? = nil

    // ✅ Photo + OCR se présente en fullScreenCover (plus stable que .sheet avec camera)
    @State private var showPhotoOCRFullScreen: Bool = false

    // ✅ On garde quickEditCard pour ne pas casser ton code existant
    @State private var quickEditCard: CardItem? = nil

    // ✅ Confirmation suppression (single + batch)
    @State private var pendingDeleteItems: [CardItem] = []
    @State private var showDeleteConfirm = false

    // ✅ Fusionner
    @State private var pendingMergeItems: [CardItem] = []
    @State private var showMergeConfirm = false

    // ✅ Force refresh UI (FavoritesStore / QuantityStore via UserDefaults)
    @State private var favoritesTick: Int = 0
    @State private var quantityTick: Int = 0

    // ✅ Multi-selection
    @State private var isSelectionMode: Bool = false
    @State private var selectedIds: Set<UUID> = []

    private let marketplace = MarketplaceService()

    // 👉 NOTE: Tout ce qui suit (enums, body, fonctions, helpers) fait partie
    //    de CVCollectionHomeView. La struct se ferme plus bas, juste avant
    //    "// MARK: - Add sheet (LOCAL)".

    // MARK: - Enums

    enum ViewMode: String, CaseIterable, Identifiable {
        case grid = "Grille"
        case list = "Liste"
        var id: String { rawValue }
    }

    enum GroupByOption: String, CaseIterable, Identifiable {
        case none = "Aucun"
        case year = "Année"
        case set = "Set"
        case player = "Joueur"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .none: return "rectangle.grid.1x2"
            case .year: return "calendar"
            case .set: return "square.stack.3d.up"
            case .player: return "person"
            }
        }
    }

    enum SectionSortOption: String, CaseIterable, Identifiable {
        case valueHigh = "Valeur ↓"
        case alphaAZ = "A → Z"
        case alphaZA = "Z → A"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .valueHigh: return "dollarsign.circle"
            case .alphaAZ: return "text.line.first.and.arrowtriangle.forward"
            case .alphaZA: return "text.line.last.and.arrowtriangle.forward"
            }
        }
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case newest = "Plus récentes"
        case oldest = "Plus anciennes"
        case titleAZ = "Titre A → Z"
        case titleZA = "Titre Z → A"
        case valueHigh = "Valeur ↓"
        case valueLow = "Valeur ↑"
        case favoritesFirst = "Favoris d’abord"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .newest: return "clock.arrow.circlepath"
            case .oldest: return "clock"
            case .titleAZ: return "text.line.first.and.arrowtriangle.forward"
            case .titleZA: return "text.line.last.and.arrowtriangle.forward"
            case .valueHigh: return "arrow.down.circle"
            case .valueLow: return "arrow.up.circle"
            case .favoritesFirst: return "star.fill"
            }
        }
    }

    enum FilterOption: String, CaseIterable, Identifiable {
        case all = "Toutes"
        case favorites = "Favoris"

        case withValue = "Avec valeur"
        case withoutValue = "Sans valeur"

        case withNotes = "Avec notes"
        case withoutNotes = "Sans notes"

        case missingPhoto = "Sans photo"
        case missingYear = "Sans année"
        case missingSet = "Sans set"
        case missingPlayer = "Sans joueur"
        case missingGrading = "Sans grading"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .all: return "line.3.horizontal.decrease.circle"
            case .favorites: return "star.fill"
            case .withValue: return "dollarsign.circle"
            case .withoutValue: return "dollarsign.circle.fill"
            case .withNotes: return "note.text"
            case .withoutNotes: return "note.text.badge.plus"
            case .missingPhoto: return "photo.badge.exclamationmark"
            case .missingYear: return "calendar.badge.exclamationmark"
            case .missingSet: return "square.stack.3d.up"
            case .missingPlayer: return "person.badge.minus"
            case .missingGrading: return "checkmark.seal"
            }
        }

        var isMissingFieldFilter: Bool {
            switch self {
            case .missingPhoto, .missingYear, .missingSet, .missingPlayer, .missingGrading:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Models helpers


    private func displayTitle(for card: CardItem) -> String {
        let p = (card.playerName ?? "").trimmedLocal
        if !p.isEmpty { return p }
        // fallback
        let t = card.title.trimmedLocal
        return t.isEmpty ? "—" : t
    }

    private func displaySubtitle(for card: CardItem) -> String? {
        // Prefer set (ex: "Series 2 - Young Guns")
        let setName = (card.setName ?? "").trimmedLocal
        if !setName.isEmpty { return setName }

        // Fallbacks (useful if set is missing)
        let year = (card.cardYear ?? "").trimmedLocal
        if !year.isEmpty { return year }

        if let g = gradingLabel(for: card) { return g }
        return nil
    }

    private func gradingLabel(for card: CardItem) -> String? {
        let company = (card.gradingCompany ?? "").trimmedLocal
        let grade = (card.gradeValue ?? "").trimmedLocal
        guard !company.isEmpty, !grade.isEmpty else { return nil }
        return "\(company) \(grade)"
    }

// MARK: - Body

var body: some View {
    let _ = favoritesTick
    let _ = quantityTick
    return applyBaseModifiers(to: mainView)
}

// MARK: - Modifiers split (fix "unable to type-check")

@ViewBuilder
private func applyBaseModifiers<Content: View>(to content: Content) -> some View {
    // NOTE: ce View est lourd (toolbars + sheets + 3 alerts + onChange). Pour éviter
    // "The compiler is unable to type-check this expression in reasonable time",
    // on casse la chaine en 3 blocs via AnyView.

    let v1 = AnyView(
        content
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Rechercher une carte…")
            .toolbar { toolbarContent }
    )

    let v2 = AnyView(
        v1
            .onAppear(perform: onFirstAppear)
            .onChange(of: groupBy) { _ in onGroupByChanged() }
            .onChange(of: sectionSort) { _ in persistUIState() }
            .onChange(of: viewMode) { _ in persistUIState() }
            .onChange(of: sort) { _ in onSortChanged() }
            .onChange(of: filter) { _ in onFilterChanged() }
            .onChange(of: searchText) { _ in onSearchChanged() }

            // ✅ IMPORTANT: si ailleurs tu fais quickEditCard = card, on redirige vers sheet unique
            .onChange(of: quickEditCard) { newValue in
                guard let card = newValue else { return }
                // ✅ Ne remplace pas une sheet déjà ouverte (ex: Photo + OCR)
                guard sheet == nil, showPhotoOCRFullScreen == false else { return }
                sheet = .quickEdit(card.id)
            }

            // 🔎 Debug : si une sheet se ferme toute seule, on veut le voir dans la console
            .onChange(of: sheet) { newValue in
                print("🧾 SHEET CHANGED ->", String(describing: newValue))
            }

            // 🔎 Debug : si le plein écran Photo+OCR se ferme, on veut le voir dans la console
            .onChange(of: showPhotoOCRFullScreen) { newValue in
                print("🧾 PHOTO OCR FULLSCREEN ->", newValue ? "presented" : "dismissed")
            }
    )

    let v3 = AnyView(
        v2
            // ✅ UNE SEULE sheet pour tout (évite conflits / fermeture)
            .sheet(item: $sheet) { route in
                switch route {
                case .addManual:
                    CVAddCardView(ownerId: uid)

                case .quickEdit:
                    if let card = quickEditCard {
                        CardQuickEditView(card: card)
                            .onDisappear {
                                favoritesTick += 1
                                quantityTick += 1
                                quickEditCard = nil
                                // ✅ pas besoin de toucher à `sheet` : SwiftUI le remet à nil tout seul
                            }
                    } else {
                        VStack { Text("—") }
                            .onAppear {
                                // Ici oui, on ferme si jamais on est dans un état invalide
                                sheet = nil
                            }
                    }
                }
            }

            // ✅ Photo + OCR en plein écran (évite les dismiss en cascade avec la caméra)
            .fullScreenCover(isPresented: $showPhotoOCRFullScreen) {
                CVPhotoOCRAddCardView(ownerId: uid)
            }

            .alert("Erreur", isPresented: uiErrorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(uiErrorText ?? "")
            }

            .alert(deleteAlertTitle, isPresented: $showDeleteConfirm) {
                Button("Annuler", role: .cancel) { pendingDeleteItems = [] }
                Button("Supprimer", role: .destructive) {
                    let toDelete = pendingDeleteItems
                    pendingDeleteItems = []
                    deleteItemsNow(toDelete)
                }
            } message: {
                Text(deleteAlertMessage)
            }

            .alert("Fusionner", isPresented: $showMergeConfirm) {
                Button("Annuler", role: .cancel) { pendingMergeItems = [] }
                Button("Fusionner", role: .destructive) {
                    let toMerge = pendingMergeItems
                    pendingMergeItems = []
                    mergeItemsNow(toMerge)
                }
            } message: {
                let count = pendingMergeItems.count
                Text(count <= 1
                     ? "Sélectionne au moins 2 cartes à fusionner."
                     : "Fusionner \(count) cartes en une seule? Les autres seront supprimées (quantités additionnées).")
            }
    )

    return v3
}

private var uiErrorPresented: Binding<Bool> {
    Binding(
        get: { uiErrorText != nil },
        set: { if !$0 { uiErrorText = nil } }
    )
}


    // MARK: - Event handlers (split)

    private func onFirstAppear() {
        restoreUIState()
        if groupBy != .none { rebuildExpandedKeys() }
    }

    private func onGroupByChanged() {
        persistUIState()
        rebuildExpandedKeys()
    }

    private func onSortChanged() {
        persistUIState()
        if isSelectionMode { pruneSelection(visibleItems: filteredCards) }
    }

    private func onFilterChanged() {
        persistUIState()
        if isSelectionMode { pruneSelection(visibleItems: filteredCards) }
        if groupBy != .none { rebuildExpandedKeys() }
    }

    private func onSearchChanged() {
        persistUIState()
        if groupBy != .none { rebuildExpandedKeys() }
        if isSelectionMode { pruneSelection(visibleItems: filteredCards) }
    }

    // MARK: - MainView

    private var mainView: some View {
        VStack(spacing: 0) {

            if cards.isEmpty {
                ContentUnavailableView(
                    "Ma collection",
                    systemImage: "rectangle.stack",
                    description: Text("Ajoute ta première carte avec le +.")
                )
            } else {
                let items = filteredCards
                let totalValue = totalEstimatedValue(of: items)
                let totalCopies = totalQuantity(of: items)

                let groupedSections: [CVCollectionSection] = {
                    if groupBy == .none { return [] }
                    return buildSections(from: items, groupBy: groupBy, sectionSort: sectionSort)
                }()

                let sectionCount = groupedSections.count
                let allExpanded = groupedAllExpanded(keys: Set(groupedSections.map { $0.key }))

                CVCollectionMiniHeader(
                    count: items.count,
                    totalCopies: totalCopies,
                    totalValueCAD: totalValue,
                    hasActiveFilter: filter != .all,
                    hasActiveSearch: !searchText.trimmedLocal.isEmpty,
                    sortLabel: sort.rawValue,
                    groupLabel: groupBy.rawValue,
                    isGrouped: groupBy != .none,
                    sectionSortLabel: sectionSort.rawValue,
                    sectionCount: sectionCount,
                    groupAllExpanded: allExpanded,
                    isFavoritesFilterOn: filter == .favorites,
                    missingFilterLabel: filter.isMissingFieldFilter ? filter.rawValue : nil,
                    onToggleAll: { toggleAllSections(keys: Set(groupedSections.map { $0.key })) },
                    onReset: {
                        filter = .all
                        sort = .newest
                        searchText = ""
                        groupBy = .none
                        sectionSort = .valueHigh
                    }
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

                Picker("Affichage", selection: $viewMode) {
                    ForEach(ViewMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                if groupBy == .none {
                    if viewMode == .grid { collectionGrid(items) }
                    else { collectionList(items) }
                } else {
                    if viewMode == .grid { groupedGrid(groupedSections) }
                    else { groupedList(groupedSections) }
                }
            }

            if isSelectionMode {
                CollectionSelectionToolbar(
                    selectedCount: selectedIds.count,
                    onMerge: { beginMergeFlow(in: filteredCards) },
                    onIncrementQty: { incrementSelectedQuantity(in: filteredCards) },
                    onDecrementQty: { decrementSelectedQuantity(in: filteredCards) },
                    onFavorite: { favoriteSelected(in: filteredCards) },
                    onUnfavorite: { unfavoriteSelected(in: filteredCards) },
                    onDelete: { confirmDeleteSelected(in: filteredCards) },
                    onCancel: { exitSelectionMode() }
                )
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {

        // ✅ Gauche : Sélection
        ToolbarItem(placement: .topBarLeading) {
            if isSelectionMode {
                Menu {
                    Button { selectAllVisible(filteredCards) } label: {
                        Label("Tout sélectionner", systemImage: "checkmark.circle")
                    }
                    Button { clearSelection() } label: {
                        Label("Tout désélectionner", systemImage: "circle")
                    }
                    Divider()
                    Button(role: .destructive) { exitSelectionMode() } label: {
                        Label("Terminer la sélection", systemImage: "xmark.circle")
                    }
                } label: {
                    Label("Tout", systemImage: "checkmark.circle")
                }
            } else {
                Button("Sélectionner") { enterSelectionMode() }
            }
        }

        // ✅ Droite : Options + Ajouter (menu)
        ToolbarItemGroup(placement: .topBarTrailing) {

            // ✅ Un seul bouton pour Filtrer/Trier/Regrouper
            if !isSelectionMode {
                Menu {
                    // --- Filtrer
                    Section("Filtrer") {
                        Button { filter = .all } label: {
                            Label(FilterOption.all.rawValue, systemImage: FilterOption.all.systemImage)
                        }
                        Button { filter = .favorites } label: {
                            Label(FilterOption.favorites.rawValue, systemImage: FilterOption.favorites.systemImage)
                        }
                        Button { filter = .withValue } label: {
                            Label(FilterOption.withValue.rawValue, systemImage: FilterOption.withValue.systemImage)
                        }
                        Button { filter = .withoutValue } label: {
                            Label(FilterOption.withoutValue.rawValue, systemImage: FilterOption.withoutValue.systemImage)
                        }
                        Button { filter = .withNotes } label: {
                            Label(FilterOption.withNotes.rawValue, systemImage: FilterOption.withNotes.systemImage)
                        }
                        Button { filter = .withoutNotes } label: {
                            Label(FilterOption.withoutNotes.rawValue, systemImage: FilterOption.withoutNotes.systemImage)
                        }
                    }

                    Section("Champs manquants") {
                        Button { filter = .missingPhoto } label: {
                            Label(FilterOption.missingPhoto.rawValue, systemImage: FilterOption.missingPhoto.systemImage)
                        }
                        Button { filter = .missingYear } label: {
                            Label(FilterOption.missingYear.rawValue, systemImage: FilterOption.missingYear.systemImage)
                        }
                        Button { filter = .missingSet } label: {
                            Label(FilterOption.missingSet.rawValue, systemImage: FilterOption.missingSet.systemImage)
                        }
                        Button { filter = .missingPlayer } label: {
                            Label(FilterOption.missingPlayer.rawValue, systemImage: FilterOption.missingPlayer.systemImage)
                        }
                        Button { filter = .missingGrading } label: {
                            Label(FilterOption.missingGrading.rawValue, systemImage: FilterOption.missingGrading.systemImage)
                        }
                    }

                    // --- Trier
                    Divider()
                    Section("Trier") {
                        ForEach(SortOption.allCases) { opt in
                            Button {
                                sort = opt
                            } label: {
                                Label(opt.rawValue, systemImage: opt.systemImage)
                            }
                        }
                    }

                    // --- Regrouper
                    Divider()
                    Section("Regrouper") {
                        ForEach(GroupByOption.allCases) { opt in
                            Button {
                                groupBy = opt
                            } label: {
                                Label(opt.rawValue, systemImage: opt.systemImage)
                            }
                        }

                        if groupBy != .none {
                            Divider()
                            Text("Trier les sections")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(SectionSortOption.allCases) { opt in
                                Button {
                                    sectionSort = opt
                                } label: {
                                    Label(opt.rawValue, systemImage: opt.systemImage)
                                }
                            }

                            Divider()
                            Button { groupBy = .none } label: {
                                Label("Désactiver le regroupement", systemImage: "xmark.circle")
                            }
                        }
                    }

                    // --- Reset rapide
                    if filter != .all || sort != .newest || !searchText.trimmedLocal.isEmpty || groupBy != .none {
                        Divider()
                        Button(role: .destructive) {
                            filter = .all
                            sort = .newest
                            searchText = ""
                            groupBy = .none
                            sectionSort = .valueHigh
                        } label: {
                            Label("Réinitialiser", systemImage: "arrow.counterclockwise")
                        }
                    }

                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }

            // ✅ Menu "Ajouter"
            Menu {
                Button {
                    showPhotoOCRFullScreen = true
                } label: {
                    Label("Photo + OCR", systemImage: "camera")
                }

                Button {
                    sheet = .addManual
                } label: {
                    Label("Ajouter manuellement", systemImage: "plus")
                }
            } label: {
                Label("Ajouter", systemImage: "plus.circle.fill")
            }
            .disabled(isSelectionMode)
        }
    }

    // MARK: - Delete alert texts

    private var deleteAlertTitle: String {
        let count = pendingDeleteItems.count
        return count <= 1 ? "Supprimer la carte" : "Supprimer des cartes"
    }

    private var deleteAlertMessage: String {
        let count = pendingDeleteItems.count
        if count <= 1 {
            return "Êtes-vous certain de vouloir supprimer cette carte? Cette action est irréversible."
        } else {
            return "Êtes-vous certain de vouloir supprimer ces \(count) cartes? Cette action est irréversible."
        }
    }

    // MARK: - Selection

    private func startSelectionAndSelect(_ card: CardItem) {
        if !isSelectionMode {
            isSelectionMode = true
            selectedIds = [card.id]
        } else {
            toggleSelected(card)
        }
    }

    private func enterSelectionMode() {
        isSelectionMode = true
        selectedIds = []
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedIds = []
    }

    private func toggleSelected(_ card: CardItem) {
        if selectedIds.contains(card.id) { selectedIds.remove(card.id) }
        else { selectedIds.insert(card.id) }
    }

    private func isSelected(_ card: CardItem) -> Bool { selectedIds.contains(card.id) }

    private func pruneSelection(visibleItems: [CardItem]) {
        let visible = Set(visibleItems.map { $0.id })
        selectedIds = selectedIds.intersection(visible)
    }

    private func selectAllVisible(_ visibleItems: [CardItem]) {
        selectedIds = Set(visibleItems.map { $0.id })
    }

    private func clearSelection() {
        selectedIds.removeAll()
    }

    // MARK: - Quantity / Favorites (tes stores existants)

    private func quantity(_ card: CardItem) -> Int { QuantityStore.quantity(id: card.id) }

    private func setQuantity(_ q: Int, for card: CardItem) {
        QuantityStore.setQuantity(max(1, q), id: card.id)
        quantityTick += 1
    }

    private func isFavorite(_ card: CardItem) -> Bool { FavoritesStore.isFavorite(id: card.id) }

    private func toggleFavorite(_ card: CardItem) {
        FavoritesStore.toggle(id: card.id)
        favoritesTick += 1
    }

    private func favoriteSelected(in currentItems: [CardItem]) {
        guard !selectedIds.isEmpty else { return }
        let ids = selectedIds
        for c in currentItems where ids.contains(c.id) { FavoritesStore.set(true, id: c.id) }
        favoritesTick += 1
        exitSelectionMode()
    }

    private func unfavoriteSelected(in currentItems: [CardItem]) {
        guard !selectedIds.isEmpty else { return }
        let ids = selectedIds
        for c in currentItems where ids.contains(c.id) { FavoritesStore.set(false, id: c.id) }
        favoritesTick += 1
        exitSelectionMode()
    }

    private func incrementSelectedQuantity(in currentItems: [CardItem]) {
        guard !selectedIds.isEmpty else { return }
        let ids = selectedIds
        for c in currentItems where ids.contains(c.id) {
            let q = QuantityStore.quantity(id: c.id)
            QuantityStore.setQuantity(q + 1, id: c.id)
        }
        quantityTick += 1
        exitSelectionMode()
    }

    private func decrementSelectedQuantity(in currentItems: [CardItem]) {
        guard !selectedIds.isEmpty else { return }
        let ids = selectedIds
        for c in currentItems where ids.contains(c.id) {
            let q = QuantityStore.quantity(id: c.id)
            QuantityStore.setQuantity(max(1, q - 1), id: c.id)
        }
        quantityTick += 1
        exitSelectionMode()
    }

    // MARK: - Merge

    private func beginMergeFlow(in currentItems: [CardItem]) {
        guard selectedIds.count >= 2 else {
            uiErrorText = "Sélectionne au moins 2 cartes pour fusionner."
            return
        }
        let ids = selectedIds
        let items = currentItems.filter { ids.contains($0.id) }
        guard items.count >= 2 else {
            uiErrorText = "Sélection invalide."
            return
        }
        pendingMergeItems = items
        showMergeConfirm = true
    }

    private func mergeItemsNow(_ items: [CardItem]) {
        guard items.count >= 2 else { return }

        let sorted = items.sorted { $0.createdAt > $1.createdAt }
        let master = sorted[0]
        let others = Array(sorted.dropFirst())

        var totalQty = QuantityStore.quantity(id: master.id)
        for o in others { totalQty += QuantityStore.quantity(id: o.id) }
        QuantityStore.setQuantity(totalQty, id: master.id)

        let anyFavorite = FavoritesStore.isFavorite(id: master.id) || others.contains(where: { FavoritesStore.isFavorite(id: $0.id) })
        if anyFavorite { FavoritesStore.set(true, id: master.id) }

        Task {
            for o in others {
                await marketplace.endListingIfExistsForDeletedCard(cardItemId: o.id.uuidString)
            }

            await MainActor.run {
                for o in others {
                    FavoritesStore.clear(id: o.id)
                    QuantityStore.clear(id: o.id)
                    modelContext.delete(o)
                }

                do {
                    try modelContext.save()
                    favoritesTick += 1
                    quantityTick += 1
                    exitSelectionMode()
                } catch {
                    uiErrorText = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Delete

    private func confirmDeleteSelected(in currentItems: [CardItem]) {
        guard !selectedIds.isEmpty else { return }
        let ids = selectedIds
        pendingDeleteItems = currentItems.filter { ids.contains($0.id) }
        showDeleteConfirm = true
    }

    private func deleteItemsNow(_ items: [CardItem]) {
        Task {
            for card in items {
                await marketplace.endListingIfExistsForDeletedCard(cardItemId: card.id.uuidString)
            }

            await MainActor.run {
                for card in items {
                    FavoritesStore.clear(id: card.id)
                    QuantityStore.clear(id: card.id)
                    modelContext.delete(card)
                }
                do {
                    try modelContext.save()
                    favoritesTick += 1
                    quantityTick += 1
                    exitSelectionMode()
                } catch {
                    uiErrorText = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Persist / Restore

    private func persistUIState() {
        storedSearchText = searchText
        storedViewModeRaw = viewMode.rawValue
        storedSortRaw = sort.rawValue
        storedFilterRaw = filter.rawValue
        storedGroupByRaw = groupBy.rawValue
        storedSectionSortRaw = sectionSort.rawValue
    }

    private func restoreUIState() {
        searchText = storedSearchText
        viewMode = ViewMode(rawValue: storedViewModeRaw) ?? .grid
        sort = SortOption(rawValue: storedSortRaw) ?? .newest
        filter = FilterOption(rawValue: storedFilterRaw) ?? .all
        groupBy = GroupByOption(rawValue: storedGroupByRaw) ?? .none
        sectionSort = SectionSortOption(rawValue: storedSectionSortRaw) ?? .valueHigh
    }

    // MARK: - Search + Filter + Sort

    private var filteredCards: [CardItem] {
        let q = searchText.trimmedLocal.lowercased()

        let searched: [CardItem]
        if q.isEmpty { searched = cards }
        else { searched = cards.filter { searchableText(for: $0).contains(q) } }

        let filtered: [CardItem] = searched.filter { card in
            switch filter {
            case .all:
                return true
            case .favorites:
                return isFavorite(card)
            case .withValue:
                return (card.estimatedPriceCAD ?? 0) > 0
            case .withoutValue:
                return (card.estimatedPriceCAD ?? 0) <= 0
            case .withNotes:
                return !(card.notes?.trimmedLocal.isEmpty ?? true)
            case .withoutNotes:
                return (card.notes?.trimmedLocal.isEmpty ?? true)
            case .missingPhoto:
                return (card.frontImageData == nil || card.frontImageData?.isEmpty == true)
            case .missingYear:
                return (card.cardYear ?? "").trimmedLocal.isEmpty
            case .missingSet:
                return (card.setName ?? "").trimmedLocal.isEmpty
            case .missingPlayer:
                return (card.playerName ?? "").trimmedLocal.isEmpty
            case .missingGrading:
                let company = (card.gradingCompany ?? "").trimmedLocal
                let grade = (card.gradeValue ?? "").trimmedLocal
                return company.isEmpty || grade.isEmpty
            }
        }

        return filtered.sorted(by: sortComparator)
    }

    private func searchableText(for card: CardItem) -> String {
        var parts: [String] = []
        parts.append(card.title)
        if let v = card.notes { parts.append(v) }
        if let v = card.playerName { parts.append(v) }
        if let v = card.cardYear { parts.append(v) }
        if let v = card.companyName { parts.append(v) }
        if let v = card.setName { parts.append(v) }
        if let v = card.cardNumber { parts.append(v) }
        if let v = card.gradingCompany { parts.append(v) }
        if let v = card.gradeValue { parts.append(v) }
        if let v = card.certificationNumber { parts.append(v) }
        return parts.joined(separator: " ").lowercased()
    }

    private func sortComparator(_ a: CardItem, _ b: CardItem) -> Bool {
        switch sort {
        case .favoritesFirst:
            let af = isFavorite(a)
            let bf = isFavorite(b)
            if af != bf { return af && !bf }
            return a.createdAt > b.createdAt
        case .newest:
            return a.createdAt > b.createdAt
        case .oldest:
            return a.createdAt < b.createdAt
        case .titleAZ:
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        case .titleZA:
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedDescending
        case .valueHigh:
            let av = a.estimatedPriceCAD ?? 0
            let bv = b.estimatedPriceCAD ?? 0
            if av != bv { return av > bv }
            return a.createdAt > b.createdAt
        case .valueLow:
            let av = a.estimatedPriceCAD ?? 0
            let bv = b.estimatedPriceCAD ?? 0
            if av != bv { return av < bv }
            return a.createdAt > b.createdAt
        }
    }

    // MARK: - Total value + copies

    private func totalEstimatedValue(of items: [CardItem]) -> Double {
        items.reduce(0) { $0 + max(0, $1.estimatedPriceCAD ?? 0) }
    }

    private func totalQuantity(of items: [CardItem]) -> Int {
        items.reduce(0) { $0 + QuantityStore.quantity(id: $1.id) }
    }

    // MARK: - Grid / List

    @ViewBuilder
    private func collectionGrid(_ items: [CardItem]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                spacing: 12
            ) {
                ForEach(items) { card in
                    if isSelectionMode {
                        Button {
                            toggleSelected(card)
                        } label: {
                            cardGridCell(card)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(isSelected(card) ? Color.accentColor : Color.clear, lineWidth: 3)
                                )
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            CardDetailView(card: card)
                        } label: {
                            cardGridCell(card)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                quickEditCard = card
                            } label: {
                                Label("Modifier rapidement", systemImage: "pencil")
                            }

                            Button {
                                toggleFavorite(card)
                            } label: {
                                Label(
                                    isFavorite(card) ? "Retirer des favoris" : "Ajouter aux favoris",
                                    systemImage: isFavorite(card) ? "star.slash" : "star"
                                )
                            }

                            Button(role: .destructive) {
                                pendingDeleteItems = [card]
                                showDeleteConfirm = true
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func collectionList(_ items: [CardItem]) -> some View {
        List {
            ForEach(items) { card in
                if isSelectionMode {
                    Button {
                        toggleSelected(card)
                    } label: {
                        cardListRow(card)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        CardDetailView(card: card)
                    } label: {
                        cardListRow(card)
                    }
                    .contextMenu {
                        Button {
                            quickEditCard = card
                        } label: {
                            Label("Modifier rapidement", systemImage: "pencil")
                        }

                        Button {
                            toggleFavorite(card)
                        } label: {
                            Label(
                                isFavorite(card) ? "Retirer des favoris" : "Ajouter aux favoris",
                                systemImage: isFavorite(card) ? "star.slash" : "star"
                            )
                        }

                        Button(role: .destructive) {
                            pendingDeleteItems = [card]
                            showDeleteConfirm = true
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Grouped grid / list

    @ViewBuilder
    private func groupedGrid(_ sections: [CVCollectionSection]) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(section)

                        if expandedSectionKeys.contains(section.key) {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                                spacing: 12
                            ) {
                                ForEach(section.items) { card in
                                    if isSelectionMode {
                                        Button {
                                            toggleSelected(card)
                                        } label: {
                                            cardGridCell(card)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                        .stroke(isSelected(card) ? Color.accentColor : Color.clear, lineWidth: 3)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        NavigationLink {
                                            CardDetailView(card: card)
                                        } label: {
                                            cardGridCell(card)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button {
                                                quickEditCard = card
                                            } label: {
                                                Label("Modifier rapidement", systemImage: "pencil")
                                            }

                                            Button {
                                                toggleFavorite(card)
                                            } label: {
                                                Label(
                                                    isFavorite(card) ? "Retirer des favoris" : "Ajouter aux favoris",
                                                    systemImage: isFavorite(card) ? "star.slash" : "star"
                                                )
                                            }

                                            Button(role: .destructive) {
                                                pendingDeleteItems = [card]
                                                showDeleteConfirm = true
                                            } label: {
                                                Label("Supprimer", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func groupedList(_ sections: [CVCollectionSection]) -> some View {
        List {
            ForEach(sections) { section in
                Section {
                    if expandedSectionKeys.contains(section.key) {
                        ForEach(section.items) { card in
                            if isSelectionMode {
                                Button {
                                    toggleSelected(card)
                                } label: {
                                    cardListRow(card)
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    CardDetailView(card: card)
                                } label: {
                                    cardListRow(card)
                                }
                                .contextMenu {
                                    Button {
                                        quickEditCard = card
                                    } label: {
                                        Label("Modifier rapidement", systemImage: "pencil")
                                    }

                                    Button {
                                        toggleFavorite(card)
                                    } label: {
                                        Label(
                                            isFavorite(card) ? "Retirer des favoris" : "Ajouter aux favoris",
                                            systemImage: isFavorite(card) ? "star.slash" : "star"
                                        )
                                    }

                                    Button(role: .destructive) {
                                        pendingDeleteItems = [card]
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Supprimer", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    sectionHeader(section)
                        .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Section header

    @ViewBuilder
    private func sectionHeader(_ section: CVCollectionSection) -> some View {
        HStack(spacing: 8) {
            Button {
                toggleSection(section.key)
            } label: {
                Image(systemName: expandedSectionKeys.contains(section.key) ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.headline)
                HStack(spacing: 8) {
                    if let subtitle = section.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                    }
                    Text("\(section.items.count) cartes")
                    Text("x\(section.totalQuantity)")
                    if section.totalValueCAD > 0 {
                        Text(String(format: "~%.0f $", section.totalValueCAD))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func toggleSection(_ key: String) {
        if expandedSectionKeys.contains(key) {
            expandedSectionKeys.remove(key)
        } else {
            expandedSectionKeys.insert(key)
        }
    }

    // MARK: - Cells

        @ViewBuilder
        private func cardGridCell(_ card: CardItem) -> some View {
            // Espace volontaire entre la photo et le texte (évite l'effet « collé »)
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    if let data = card.frontImageData,
                       let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            // 📐 Carte verticale (ratio ~ 2.5 x 3.5)
                            .aspectRatio(2.5/3.5, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                                .aspectRatio(2.5/3.5, contentMode: .fill)
                                .frame(maxWidth: .infinity)
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if isFavorite(card) {
                        Image(systemName: "star.fill")
                            .imageScale(.small)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(6)
                    }
                }
                .padding(.bottom, 2)

                Text(displayTitle(for: card))
                    .font(.headline)
                    .lineLimit(2)

                if let subtitle = displaySubtitle(for: card) {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack {
                    if quantity(card) > 1 {
                        Text("x\(quantity(card))")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.thinMaterial)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    if let v = card.estimatedPriceCAD, v > 0 {
                        Text("~\(Int(v)) $")
                            .font(.caption2)
                            .fontWeight(.semibold)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.systemBackground))
                    .shadow(radius: 1, x: 0, y: 1)
            )
        }

        @ViewBuilder
        private func cardListRow(_ card: CardItem) -> some View {
            HStack(spacing: 10) {
                ZStack {
                    if let data = card.frontImageData,
                       let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 80)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 60, height: 80)
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                    }

                    if isFavorite(card) {
                        Image(systemName: "star.fill")
                            .imageScale(.small)
                            .padding(4)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .offset(x: 20, y: -32)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle(for: card))
                        .font(.headline)
                        .lineLimit(2)

                    if let subtitle = displaySubtitle(for: card) {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if let v = card.estimatedPriceCAD, v > 0 {
                        Text(String(format: "~%.0f $", v))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }

                    if quantity(card) > 1 {
                        Text("x\(quantity(card))")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.thinMaterial)
                            .clipShape(Capsule())
                    }

                    if isSelectionMode && isSelected(card) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(.vertical, 4)
        }

    // MARK: - Grouped sections helpers

    private func buildSections(
        from items: [CardItem],
        groupBy: GroupByOption,
        sectionSort: SectionSortOption
    ) -> [CVCollectionSection] {
        guard groupBy != .none else { return [] }

        var dict: [String: [CardItem]] = [:]

        for card in items {
            let key = sectionKey(for: card, groupBy: groupBy)
            dict[key, default: []].append(card)
        }

        var sections: [CVCollectionSection] = dict.map { key, cards in
            let title = key
            let count = cards.count
            let totalValue = totalEstimatedValue(of: cards)
            let totalQty = totalQuantity(of: cards)

            let subtitle: String
            switch groupBy {
            case .year:
                subtitle = count == 1 ? "1 carte" : "\(count) cartes"
            case .set:
                subtitle = count == 1 ? "1 carte" : "\(count) cartes"
            case .player:
                subtitle = count == 1 ? "1 carte" : "\(count) cartes"
            case .none:
                subtitle = ""
            }

            return CVCollectionSection(
                key: key,
                title: title,
                subtitle: subtitle,
                totalValueCAD: totalValue,
                totalQuantity: totalQty,
                items: cards
            )
        }

        switch sectionSort {
        case .valueHigh:
            sections.sort { $0.totalValueCAD > $1.totalValueCAD }
        case .alphaAZ:
            sections.sort {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .alphaZA:
            sections.sort {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending
            }
        }

        return sections
    }

    private func sectionKey(for card: CardItem, groupBy: GroupByOption) -> String {
        switch groupBy {
        case .none:
            return "Toutes"
        case .year:
            let year = (card.cardYear ?? "").trimmedLocal
            return year.isEmpty ? "Année inconnue" : year
        case .set:
            let setName = (card.setName ?? "").trimmedLocal
            return setName.isEmpty ? "Set inconnu" : setName
        case .player:
            let player = (card.playerName ?? "").trimmedLocal
            return player.isEmpty ? "Joueur inconnu" : player
        }
    }

    // MARK: - Expand / collapse helpers

    private func rebuildExpandedKeys() {
        guard groupBy != .none else {
            expandedSectionKeys = []
            return
        }

        let items = filteredCards
        let sections = buildSections(from: items, groupBy: groupBy, sectionSort: sectionSort)
        expandedSectionKeys = Set(sections.map { $0.key })
    }

    private func groupedAllExpanded(keys: Set<String>) -> Bool {
        guard !keys.isEmpty else { return false }
        return keys.allSatisfy { expandedSectionKeys.contains($0) }
    }

    private func toggleAllSections(keys: Set<String>) {
        if groupedAllExpanded(keys: keys) {
            expandedSectionKeys.subtract(keys)
        } else {
            expandedSectionKeys.formUnion(keys)
        }
    }

} // ✅ end of CVCollectionHomeView

// MARK: - Add sheet (LOCAL)

private struct CVAddCardView: View {

    let ownerId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var title: String = ""
    @State private var notes: String = ""

    @State private var pickedItem: PhotosPickerItem? = nil
    @State private var imageData: Data? = nil
    @State private var isLoadingImage = false

    @State private var uiError: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Carte") {
                    TextField("Titre", text: $title)
                    TextField("Notes (optionnel)", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section("Photo") {
                    PhotosPicker(selection: $pickedItem, matching: .images) {
                        HStack {
                            Image(systemName: "photo.on.rectangle")
                            Text(imageData == nil ? "Choisir une photo" : "Changer la photo")
                        }
                    }

                    if isLoadingImage {
                        ProgressView()
                    } else if let data = imageData, let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(.vertical, 6)
                    } else {
                        Text("Aucune photo.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let uiError, !uiError.isEmpty {
                    Section {
                        Text("⚠️ \(uiError)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Ajouter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Enregistrer") { save() }
                }
            }
            .onChange(of: pickedItem) { _, newValue in
                guard let newValue else { return }
                Task { await loadImage(from: newValue) }
            }
        }
    }

    private func loadImage(from item: PhotosPickerItem) async {
        await MainActor.run {
            isLoadingImage = true
            uiError = nil
        }

        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                await MainActor.run {
                    self.imageData = data
                    self.isLoadingImage = false
                }
            } else {
                await MainActor.run {
                    self.isLoadingImage = false
                    self.uiError = "Impossible de lire l’image."
                }
            }
        } catch {
            await MainActor.run {
                self.isLoadingImage = false
                self.uiError = error.localizedDescription
            }
        }
    }

    private func save() {
        uiError = nil

        let t = title.trimmedLocal
        guard !t.isEmpty else {
            uiError = "Le titre est obligatoire."
            return
        }

        let n = notes.trimmedLocal
        let finalNotes: String? = n.isEmpty ? nil : n

        let card = CardItem(
            ownerId: ownerId,
            title: t,
            notes: finalNotes,
            frontImageData: imageData
        )

        modelContext.insert(card)

        do {
            try modelContext.save()
            dismiss()
        } catch {
            uiError = error.localizedDescription
        }
    }
}

// MARK: - Mini header (stats + filtres)

private struct CVCollectionMiniHeader: View {
    let count: Int
    let totalCopies: Int
    let totalValueCAD: Double

    let hasActiveFilter: Bool
    let hasActiveSearch: Bool

    let sortLabel: String
    let groupLabel: String
    let isGrouped: Bool
    let sectionSortLabel: String
    let sectionCount: Int
    let groupAllExpanded: Bool
    let isFavoritesFilterOn: Bool
    let missingFilterLabel: String?

    let onToggleAll: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(count) carte\(count > 1 ? "s" : "")")
                    .font(.headline)
                if totalCopies > count {
                    Text("x\(totalCopies)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if totalValueCAD > 0 {
                    Text(String(format: "~%.0f $", totalValueCAD))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            }

            HStack(spacing: 6) {
                if hasActiveFilter || hasActiveSearch || isGrouped {
                    if hasActiveFilter {
                        if isFavoritesFilterOn {
                            pill("Favoris", systemImage: "star.fill")
                        } else if let missing = missingFilterLabel {
                            pill(missing, systemImage: "exclamationmark.circle")
                        } else {
                            pill("Filtre: \(sortLabel)", systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }

                    if hasActiveSearch {
                        pill("Recherche", systemImage: "magnifyingglass")
                    }

                    if isGrouped {
                        pill("Groupé: \(groupLabel)", systemImage: "square.stack.3d.up")
                        if sectionCount > 0 {
                            Button {
                                onToggleAll()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: groupAllExpanded ? "chevron.down" : "chevron.right")
                                    Text("\(sectionCount) section\(sectionCount > 1 ? "s" : "")")
                                }
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.thinMaterial)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button(role: .destructive) {
                        onReset()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Réinit.")
                        }
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Aucun filtre actif")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pill(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial)
        .clipShape(Capsule())
    }
}

// MARK: - Section model

private struct CVCollectionSection: Identifiable {
    let key: String
    let title: String
    let subtitle: String?
    let totalValueCAD: Double
    let totalQuantity: Int
    let items: [CardItem]

    var id: String { key }
}

// MARK: - Helpers

private extension String {
    var trimmedLocal: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - MarketplaceService helper

private extension MarketplaceService {

    /// Termine (ended) les annonces liées à une CardItem supprimée.
    /// - Respecte le comportement déjà prévu: fixedPrice active/paused -> ended, auction active avec 0 bid -> ended.
    func endListingIfExistsForDeletedCard(cardItemId: String) async {
        guard let user = Auth.auth().currentUser else { return }

        do {
            let db = Firestore.firestore()
            let snap = try await db.collection("listings")
                .whereField("sellerId", isEqualTo: user.uid)
                .whereField("cardItemId", isEqualTo: cardItemId)
                .getDocuments()

            guard !snap.documents.isEmpty else { return }

            let batch = db.batch()
            let ts = Timestamp(date: Date())

            for doc in snap.documents {
                let data = doc.data()
                let status = (data["status"] as? String) ?? ""
                if status == "sold" || status == "ended" { continue }

                let type = (data["type"] as? String) ?? ""

                if type == "fixedPrice" {
                    if status == "active" || status == "paused" {
                        batch.updateData([
                            "status": "ended",
                            "endedAt": ts,
                            "updatedAt": ts
                        ], forDocument: doc.reference)
                    }
                }

                if type == "auction" {
                    if status == "active" {
                        let bidCount = (data["bidCount"] as? Int) ?? 0
                        if bidCount == 0 {
                            batch.updateData([
                                "status": "ended",
                                "endedAt": ts,
                                "updatedAt": ts
                            ], forDocument: doc.reference)
                        }
                    }
                }
            }

            try await batch.commit()
        } catch {
            print("⚠️ endListingIfExistsForDeletedCard error:", error.localizedDescription)
        }
    }
}
