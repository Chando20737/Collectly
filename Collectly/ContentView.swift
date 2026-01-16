//
//  ContentView 2.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-15.
//
import SwiftUI
import SwiftData
import UIKit
import PhotosUI

// ✅ IMPORTANT
// Ce fichier corrige le problème “tous les users voient la même collection”
// en filtrant SwiftData par `CardItem.ownerId == uid`.
//
// ⚠️ Assure-toi que ton modèle SwiftData CardItem contient bien:
//     var ownerId: String
// (ou String? mais idéalement String non-optionnel)

struct ContentView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        NavigationStack {

            // ✅ Déconnecté -> on cache la collection
            if session.user == nil {
                ContentUnavailableView(
                    "Ma collection",
                    systemImage: "rectangle.stack",
                    description: Text("Connecte-toi pour voir ta collection.")
                )
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)

            } else {
                // ✅ Connecté -> vraie collection filtrée par user
                MyCollectionInnerView(uid: session.user!.uid)
            }
        }
    }
}

// MARK: - ✅ Inner view (filtrée par ownerId)

private struct MyCollectionInnerView: View {

    let uid: String

    @Environment(\.modelContext) private var modelContext

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

    @State private var searchText: String = ""
    @State private var viewMode: ViewMode = .grid
    @State private var sort: SortOption = .newest
    @State private var filter: FilterOption = .all

    // ✅ Regroupement + tri des sections
    @State private var groupBy: GroupByOption = .none
    @State private var sectionSort: SectionSortOption = .valueHigh
    @State private var expandedSectionKeys: Set<String> = []

    @State private var uiErrorText: String? = nil
    @State private var showAddSheet = false

    // ✅ Quick edit
    @State private var quickEditCard: CardItem? = nil

    // ✅ Confirmation suppression (single + batch)
    @State private var pendingDeleteItems: [CardItem] = []
    @State private var showDeleteConfirm = false

    // ✅ Fusionner
    @State private var pendingMergeItems: [CardItem] = []
    @State private var showMergeConfirm = false

    // ✅ Forcer refresh UI quand on toggle favoris / quantité (UserDefaults)
    @State private var favoritesTick: Int = 0
    @State private var quantityTick: Int = 0

    // ✅ Multi-selection
    @State private var isSelectionMode: Bool = false
    @State private var selectedIds: Set<UUID> = []

    private let marketplace = MarketplaceService()

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

    // ✅ AJOUT: filtres “Champs manquants”
    enum FilterOption: String, CaseIterable, Identifiable {
        case all = "Toutes"
        case favorites = "Favoris"

        case withValue = "Avec valeur"
        case withoutValue = "Sans valeur"

        case withNotes = "Avec notes"
        case withoutNotes = "Sans notes"

        // Champs manquants
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
            case .missingSet: return "square.stack.3d.up.badge.exclamationmark"
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

    var body: some View {

        let _ = favoritesTick // force refresh when favorites change
        let _ = quantityTick  // force refresh when quantity changes

        let items = filteredSortedAndFilteredCards
        let totalValue = totalEstimatedValue(of: items)
        let totalCopies = totalQuantity(of: items)

        let groupedSections: [CollectionSection] = {
            if groupBy == .none { return [] }
            return buildSections(from: items, groupBy: groupBy, sectionSort: sectionSort)
        }()

        let sectionCount = groupedSections.count
        let allExpanded = groupedAllExpanded(keys: Set(groupedSections.map { $0.key }))

        VStack(spacing: 0) {

            if items.isEmpty {
                ContentUnavailableView(
                    "Ma collection",
                    systemImage: "rectangle.stack",
                    description: Text(emptyMessage)
                )
            } else {

                CollectionMiniHeader(
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
                        Haptics.light()
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

                // ✅ Contenu (groupé / non groupé)
                if groupBy == .none {
                    if viewMode == .grid {
                        collectionGrid(items)
                    } else {
                        collectionList(items)
                    }
                } else {
                    if viewMode == .grid {
                        groupedGrid(groupedSections)
                    } else {
                        groupedList(groupedSections)
                    }
                }
            }

            // ✅ Barre multi-sélection
            if isSelectionMode {
                CollectionSelectionToolbar(
                    selectedCount: selectedIds.count,
                    onMerge: { beginMergeFlow(in: items) },
                    onIncrementQty: { incrementSelectedQuantity(in: items) },
                    onDecrementQty: { decrementSelectedQuantity(in: items) },
                    onFavorite: { favoriteSelected(in: items) },
                    onUnfavorite: { unfavoriteSelected(in: items) },
                    onDelete: { confirmDeleteSelected(in: items) },
                    onCancel: { exitSelectionMode() }
                )
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Rechercher une carte…")
        .toolbar {

            // ✅ Multi-select toggle + Tout sélectionner
            ToolbarItem(placement: .topBarLeading) {
                if isSelectionMode {
                    Menu {
                        Button {
                            selectAllVisible(items)
                        } label: {
                            Label("Tout sélectionner", systemImage: "checkmark.circle")
                        }

                        Button {
                            clearSelection()
                        } label: {
                            Label("Tout désélectionner", systemImage: "circle")
                        }

                        Divider()

                        Button(role: .destructive) {
                            exitSelectionMode()
                        } label: {
                            Label("Terminer la sélection", systemImage: "xmark.circle")
                        }
                    } label: {
                        Label("Tout", systemImage: "checkmark.circle")
                    }
                    .accessibilityLabel("Actions de sélection")
                } else {
                    Button("Sélectionner") {
                        enterSelectionMode()
                    }
                    .accessibilityLabel("Activer la sélection")
                }
            }

            // ✅ Filtrer / Trier / Regrouper masqués en sélection (plus clair)
            if !isSelectionMode {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {

                        // ✅ 1) Base
                        Section("Filtrer") {
                            Picker("Filtrer", selection: $filter) {
                                Label(FilterOption.all.rawValue, systemImage: FilterOption.all.systemImage).tag(FilterOption.all)
                                Label(FilterOption.favorites.rawValue, systemImage: FilterOption.favorites.systemImage).tag(FilterOption.favorites)
                                Label(FilterOption.withValue.rawValue, systemImage: FilterOption.withValue.systemImage).tag(FilterOption.withValue)
                                Label(FilterOption.withoutValue.rawValue, systemImage: FilterOption.withoutValue.systemImage).tag(FilterOption.withoutValue)
                                Label(FilterOption.withNotes.rawValue, systemImage: FilterOption.withNotes.systemImage).tag(FilterOption.withNotes)
                                Label(FilterOption.withoutNotes.rawValue, systemImage: FilterOption.withoutNotes.systemImage).tag(FilterOption.withoutNotes)
                            }
                        }

                        Divider()

                        // ✅ 2) Champs manquants
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

                        if filter != .all {
                            Divider()
                            Button(role: .destructive) {
                                filter = .all
                            } label: {
                                Label("Réinitialiser les filtres", systemImage: "xmark.circle")
                            }
                        }

                    } label: {
                        Image(systemName: filter == .all
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filtrer")
                }

                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Trier", selection: $sort) {
                            ForEach(SortOption.allCases) { opt in
                                Label(opt.rawValue, systemImage: opt.systemImage).tag(opt)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Trier")
                }

                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Regrouper par", selection: $groupBy) {
                            ForEach(GroupByOption.allCases) { opt in
                                Label(opt.rawValue, systemImage: opt.systemImage).tag(opt)
                            }
                        }

                        if groupBy != .none {
                            Divider()
                            Picker("Trier les sections", selection: $sectionSort) {
                                ForEach(SectionSortOption.allCases) { opt in
                                    Label(opt.rawValue, systemImage: opt.systemImage).tag(opt)
                                }
                            }
                        }

                        if groupBy != .none {
                            Divider()
                            Button { groupBy = .none } label: {
                                Label("Désactiver le regroupement", systemImage: "xmark.circle")
                            }
                        }
                    } label: {
                        Image(systemName: groupBy == .none ? "square.grid.2x2" : "square.grid.2x2.fill")
                    }
                    .accessibilityLabel("Regrouper")
                }
            }

            // ✅ Ajouter (désactivé en sélection)
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Ajouter une carte")
                    .disabled(isSelectionMode)
            }
        }
        .onChange(of: groupBy) { _, _ in
            persistUIState()
            rebuildExpandedKeys()
        }
        .onChange(of: sectionSort) { _, _ in persistUIState() }
        .onChange(of: searchText) { _, _ in
            persistUIState()
            if groupBy != .none { rebuildExpandedKeys() }
            if isSelectionMode { pruneSelection(visibleItems: filteredSortedAndFilteredCards) }
        }
        .onChange(of: viewMode) { _, _ in persistUIState() }
        .onChange(of: sort) { _, _ in
            persistUIState()
            if isSelectionMode { pruneSelection(visibleItems: filteredSortedAndFilteredCards) }
        }
        .onChange(of: filter) { _, _ in
            persistUIState()
            if isSelectionMode { pruneSelection(visibleItems: filteredSortedAndFilteredCards) }
        }
        .sheet(isPresented: $showAddSheet) {
            // ✅ IMPORTANT: ton AddCardView doit sauver ownerId = uid
            AddCardView()
        }
        .sheet(item: $quickEditCard) { card in
            CardQuickEditView(card: card)
                .onDisappear {
                    favoritesTick += 1
                    quantityTick += 1
                }
        }
        .alert("Erreur", isPresented: Binding(
            get: { uiErrorText != nil },
            set: { if !$0 { uiErrorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(uiErrorText ?? "")
        }

        // ✅ CONFIRMATION SUPPRESSION (single + batch)
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
        .onAppear {
            restoreUIState()
            if groupBy != .none { rebuildExpandedKeys() }
        }
    }

    // MARK: - Texte alert suppression

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

    // MARK: - ✅ Long press => selection mode + check + haptics

    private func startSelectionAndSelect(_ card: CardItem) {
        if !isSelectionMode {
            isSelectionMode = true
            selectedIds = [card.id]
            Haptics.selectionStart()
        } else {
            if selectedIds.contains(card.id) {
                selectedIds.remove(card.id)
                Haptics.selectionToggleOff()
            } else {
                selectedIds.insert(card.id)
                Haptics.selectionToggleOn()
            }
        }
    }

    // MARK: - Multi-selection

    private func enterSelectionMode() {
        isSelectionMode = true
        selectedIds = []
        Haptics.selectionStart()
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedIds = []
        Haptics.light()
    }

    private func toggleSelected(_ card: CardItem) {
        if selectedIds.contains(card.id) {
            selectedIds.remove(card.id)
            Haptics.selectionToggleOff()
        } else {
            selectedIds.insert(card.id)
            Haptics.selectionToggleOn()
        }
    }

    private func isSelected(_ card: CardItem) -> Bool { selectedIds.contains(card.id) }

    private func pruneSelection(visibleItems: [CardItem]) {
        let visible = Set(visibleItems.map { $0.id })
        selectedIds = selectedIds.intersection(visible)
    }

    private func selectAllVisible(_ visibleItems: [CardItem]) {
        selectedIds = Set(visibleItems.map { $0.id })
        Haptics.medium()
    }

    private func clearSelection() {
        selectedIds.removeAll()
        Haptics.light()
    }

    // MARK: - Quantity

    private func quantity(_ card: CardItem) -> Int {
        CollectionQuantityStore.quantity(id: card.id)
    }

    private func setQuantity(_ q: Int, for card: CardItem) {
        CollectionQuantityStore.setQuantity(max(1, q), id: card.id)
        quantityTick += 1
    }

    private func incrementSelectedQuantity(in currentItems: [CardItem]) {
        guard !selectedIds.isEmpty else { return }
        let ids = selectedIds
        for c in currentItems where ids.contains(c.id) {
            let q = CollectionQuantityStore.quantity(id: c.id)
            CollectionQuantityStore.setQuantity(q + 1, id: c.id)
        }
        quantityTick += 1
        Haptics.success()
        exitSelectionMode()
    }

    private func decrementSelectedQuantity(in currentItems: [CardItem]) {
        guard !selectedIds.isEmpty else { return }
        let ids = selectedIds
        for c in currentItems where ids.contains(c.id) {
            let q = CollectionQuantityStore.quantity(id: c.id)
            CollectionQuantityStore.setQuantity(max(1, q - 1), id: c.id)
        }
        quantityTick += 1
        Haptics.success()
        exitSelectionMode()
    }

    // MARK: - Favorites

    private func toggleFavorite(_ card: CardItem) {
        FavoritesStore.toggle(id: card.id)
        favoritesTick += 1
        Haptics.light()
    }

    private func isFavorite(_ card: CardItem) -> Bool {
        FavoritesStore.isFavorite(id: card.id)
    }

    private func favoriteSelected(in currentItems: [CardItem]) {
        guard !selectedIds.isEmpty else { return }
        let ids = selectedIds
        for c in currentItems where ids.contains(c.id) { FavoritesStore.set(true, id: c.id) }
        favoritesTick += 1
        Haptics.success()
        exitSelectionMode()
    }

    private func unfavoriteSelected(in currentItems: [CardItem]) {
        guard !selectedIds.isEmpty else { return }
        let ids = selectedIds
        for c in currentItems where ids.contains(c.id) { FavoritesStore.set(false, id: c.id) }
        favoritesTick += 1
        Haptics.success()
        exitSelectionMode()
    }

    // MARK: - Merge

    private func beginMergeFlow(in currentItems: [CardItem]) {
        guard selectedIds.count >= 2 else {
            Haptics.warning()
            uiErrorText = "Sélectionne au moins 2 cartes pour fusionner."
            return
        }

        let ids = selectedIds
        let items = currentItems.filter { ids.contains($0.id) }

        guard items.count >= 2 else {
            Haptics.warning()
            uiErrorText = "Sélection invalide."
            return
        }

        pendingMergeItems = items
        Haptics.warning()
        showMergeConfirm = true
    }

    private func mergeItemsNow(_ items: [CardItem]) {
        guard items.count >= 2 else { return }

        // Master = plus récente
        let sorted = items.sorted { $0.createdAt > $1.createdAt }
        let master = sorted[0]
        let others = Array(sorted.dropFirst())

        // Addition des quantités
        var totalQty = CollectionQuantityStore.quantity(id: master.id)
        for o in others {
            totalQty += CollectionQuantityStore.quantity(id: o.id)
        }
        CollectionQuantityStore.setQuantity(totalQty, id: master.id)

        // Fusion best-effort
        mergeFillIfMissing(master: master, from: others)

        // Favoris: si un des items est favori -> master favori
        let anyFavorite = FavoritesStore.isFavorite(id: master.id) || others.contains(where: { FavoritesStore.isFavorite(id: $0.id) })
        if anyFavorite { FavoritesStore.set(true, id: master.id) }

        Task {
            for o in others {
                await marketplace.endListingIfExistsForDeletedCard(cardItemId: o.id.uuidString)
            }

            await MainActor.run {
                for o in others {
                    FavoritesStore.clear(id: o.id)
                    CollectionQuantityStore.clear(id: o.id)
                    modelContext.delete(o)
                }

                do {
                    try modelContext.save()
                    favoritesTick += 1
                    quantityTick += 1
                    Haptics.success()
                    exitSelectionMode()
                } catch {
                    uiErrorText = error.localizedDescription
                    Haptics.error()
                }
            }
        }
    }

    private func mergeFillIfMissing(master: CardItem, from others: [CardItem]) {

        func pickFirstNonEmptyString(_ keyPath: KeyPath<CardItem, String?>) -> String? {
            for o in others {
                let v = (o[keyPath: keyPath] ?? "").trimmedLocal
                if !v.isEmpty { return v }
            }
            return nil
        }

        func pickFirstNonNilData(_ keyPath: KeyPath<CardItem, Data?>) -> Data? {
            for o in others {
                if let d = o[keyPath: keyPath], !d.isEmpty { return d }
            }
            return nil
        }

        // Photo
        if master.frontImageData == nil || master.frontImageData?.isEmpty == true {
            if let d = pickFirstNonNilData(\.frontImageData) {
                master.frontImageData = d
            }
        }

        // Notes
        if (master.notes ?? "").trimmedLocal.isEmpty {
            if let v = pickFirstNonEmptyString(\.notes) { master.notes = v }
        }

        // Valeur (prend première > 0)
        if (master.estimatedPriceCAD ?? 0) <= 0 {
            for o in others {
                if let v = o.estimatedPriceCAD, v > 0 {
                    master.estimatedPriceCAD = v
                    break
                }
            }
        }

        // Champs texte
        if (master.playerName ?? "").trimmedLocal.isEmpty {
            if let v = pickFirstNonEmptyString(\.playerName) { master.playerName = v }
        }
        if (master.cardYear ?? "").trimmedLocal.isEmpty {
            if let v = pickFirstNonEmptyString(\.cardYear) { master.cardYear = v }
        }
        if (master.setName ?? "").trimmedLocal.isEmpty {
            if let v = pickFirstNonEmptyString(\.setName) { master.setName = v }
        }
        if (master.companyName ?? "").trimmedLocal.isEmpty {
            if let v = pickFirstNonEmptyString(\.companyName) { master.companyName = v }
        }
        if (master.cardNumber ?? "").trimmedLocal.isEmpty {
            if let v = pickFirstNonEmptyString(\.cardNumber) { master.cardNumber = v }
        }
        if (master.acquisitionSource ?? "").trimmedLocal.isEmpty {
            if let v = pickFirstNonEmptyString(\.acquisitionSource) { master.acquisitionSource = v }
        }

        // Grading: si master incomplet, copie un ensemble complet
        let masterCompany = (master.gradingCompany ?? "").trimmedLocal
        let masterGrade = (master.gradeValue ?? "").trimmedLocal
        let masterCert = (master.certificationNumber ?? "").trimmedLocal
        let masterHasCompleteGrading = !masterCompany.isEmpty && !masterGrade.isEmpty

        if !masterHasCompleteGrading {
            for o in others {
                let c = (o.gradingCompany ?? "").trimmedLocal
                let g = (o.gradeValue ?? "").trimmedLocal
                if !c.isEmpty && !g.isEmpty {
                    master.gradingCompany = c
                    master.gradeValue = g

                    let cert = (o.certificationNumber ?? "").trimmedLocal
                    if masterCert.isEmpty && !cert.isEmpty {
                        master.certificationNumber = cert
                    }
                    break
                }
            }
        }
    }

    // MARK: - Confirm delete (batch)

    private func confirmDeleteSelected(in currentItems: [CardItem]) {
        guard !selectedIds.isEmpty else { return }
        let ids = selectedIds
        pendingDeleteItems = currentItems.filter { ids.contains($0.id) }
        Haptics.warning()
        showDeleteConfirm = true
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

    // MARK: - Grid (normal)

    @ViewBuilder
    private func collectionGrid(_ items: [CardItem]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10, alignment: .top),
                    GridItem(.flexible(), spacing: 10, alignment: .top)
                ],
                spacing: 10
            ) {
                ForEach(items) { card in
                    if isSelectionMode {
                        Button {
                            toggleSelected(card)
                        } label: {
                            CollectionGridCard(
                                card: card,
                                isFavorite: isFavorite(card),
                                quantity: quantity(card),
                                onToggleFavorite: { toggleFavorite(card) },
                                isSelected: isSelected(card),
                                selectionMode: true,
                                onToggleSelection: { toggleSelected(card) }
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            CardDetailView(card: card)
                        } label: {
                            CollectionGridCard(
                                card: card,
                                isFavorite: isFavorite(card),
                                quantity: quantity(card),
                                onToggleFavorite: { toggleFavorite(card) },
                                isSelected: false,
                                selectionMode: false,
                                onToggleSelection: {}
                            )
                        }
                        .buttonStyle(GridPressableLinkStyle())
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.35)
                                .onEnded { _ in startSelectionAndSelect(card) }
                        )
                        .contextMenu {
                            Button { toggleFavorite(card) } label: {
                                Label(isFavorite(card) ? "Retirer des favoris" : "Ajouter aux favoris",
                                      systemImage: isFavorite(card) ? "star.slash" : "star")
                            }
                            Button { quickEditCard = card } label: {
                                Label("Modifier", systemImage: "pencil")
                            }
                            Divider()
                            Button {
                                let newQ = quantity(card) + 1
                                setQuantity(newQ, for: card)
                                Haptics.light()
                            } label: {
                                Label("Ajouter un exemplaire (+1)", systemImage: "plus.circle")
                            }
                            Divider()
                            Button(role: .destructive) {
                                pendingDeleteItems = [card]
                                showDeleteConfirm = true
                                Haptics.warning()
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
    }

    // MARK: - List (normal)

    @ViewBuilder
    private func collectionList(_ items: [CardItem]) -> some View {
        List {
            ForEach(items) { card in
                if isSelectionMode {
                    Button {
                        toggleSelected(card)
                    } label: {
                        CollectionListRow(
                            card: card,
                            isFavorite: isFavorite(card),
                            quantity: quantity(card),
                            onToggleFavorite: { toggleFavorite(card) },
                            isSelected: isSelected(card),
                            selectionMode: true,
                            onToggleSelection: { toggleSelected(card) }
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                } else {
                    NavigationLink {
                        CardDetailView(card: card)
                    } label: {
                        CollectionListRow(
                            card: card,
                            isFavorite: isFavorite(card),
                            quantity: quantity(card),
                            onToggleFavorite: { toggleFavorite(card) },
                            isSelected: false,
                            selectionMode: false,
                            onToggleSelection: {}
                        )
                    }
                    .buttonStyle(ListPressableLinkStyle())
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.35)
                            .onEnded { _ in startSelectionAndSelect(card) }
                    )
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button { quickEditCard = card } label: {
                            Label("Modifier", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { toggleFavorite(card) } label: {
                            Label(isFavorite(card) ? "Unfavorite" : "Favori",
                                  systemImage: isFavorite(card) ? "star.slash" : "star.fill")
                        }
                        .tint(.yellow)

                        Button {
                            let newQ = quantity(card) + 1
                            setQuantity(newQ, for: card)
                            Haptics.light()
                        } label: {
                            Label("+1", systemImage: "plus.circle")
                        }
                        .tint(.mint)

                        Button(role: .destructive) {
                            pendingDeleteItems = [card]
                            showDeleteConfirm = true
                            Haptics.warning()
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            }
            .onDelete { offsets in
                guard !isSelectionMode else { return }
                let toDelete = offsets.compactMap { idx in
                    items.indices.contains(idx) ? items[idx] : nil
                }
                guard !toDelete.isEmpty else { return }
                pendingDeleteItems = toDelete
                showDeleteConfirm = true
                Haptics.warning()
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Grouped Grid

    @ViewBuilder
    private func groupedGrid(_ sections: [CollectionSection]) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(sections) { section in
                    SectionCard(
                        title: section.key,
                        count: section.items.count,
                        valueCAD: section.totalValueCAD,
                        isExpanded: bindingForSection(section.key)
                    ) {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 10, alignment: .top),
                                GridItem(.flexible(), spacing: 10, alignment: .top)
                            ],
                            spacing: 10
                        ) {
                            ForEach(section.items) { card in
                                if isSelectionMode {
                                    Button {
                                        toggleSelected(card)
                                    } label: {
                                        CollectionGridCard(
                                            card: card,
                                            isFavorite: isFavorite(card),
                                            quantity: quantity(card),
                                            onToggleFavorite: { toggleFavorite(card) },
                                            isSelected: isSelected(card),
                                            selectionMode: true,
                                            onToggleSelection: { toggleSelected(card) }
                                        )
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    NavigationLink {
                                        CardDetailView(card: card)
                                    } label: {
                                        CollectionGridCard(
                                            card: card,
                                            isFavorite: isFavorite(card),
                                            quantity: quantity(card),
                                            onToggleFavorite: { toggleFavorite(card) },
                                            isSelected: false,
                                            selectionMode: false,
                                            onToggleSelection: {}
                                        )
                                    }
                                    .buttonStyle(GridPressableLinkStyle())
                                    .simultaneousGesture(
                                        LongPressGesture(minimumDuration: 0.35)
                                            .onEnded { _ in startSelectionAndSelect(card) }
                                    )
                                    .contextMenu {
                                        Button { toggleFavorite(card) } label: {
                                            Label(isFavorite(card) ? "Retirer des favoris" : "Ajouter aux favoris",
                                                  systemImage: isFavorite(card) ? "star.slash" : "star")
                                        }
                                        Button { quickEditCard = card } label: {
                                            Label("Modifier", systemImage: "pencil")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            pendingDeleteItems = [card]
                                            showDeleteConfirm = true
                                            Haptics.warning()
                                        } label: {
                                            Label("Supprimer", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    }
                    .padding(.horizontal, 10)
                }
            }
            .padding(.bottom, 14)
        }
    }

    // MARK: - Grouped List

    @ViewBuilder
    private func groupedList(_ sections: [CollectionSection]) -> some View {
        List {
            ForEach(sections) { section in
                Section {
                    if expandedSectionKeys.contains(section.key) {
                        ForEach(section.items) { card in
                            if isSelectionMode {
                                Button {
                                    toggleSelected(card)
                                } label: {
                                    CollectionListRow(
                                        card: card,
                                        isFavorite: isFavorite(card),
                                        quantity: quantity(card),
                                        onToggleFavorite: { toggleFavorite(card) },
                                        isSelected: isSelected(card),
                                        selectionMode: true,
                                        onToggleSelection: { toggleSelected(card) }
                                    )
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            } else {
                                NavigationLink {
                                    CardDetailView(card: card)
                                } label: {
                                    CollectionListRow(
                                        card: card,
                                        isFavorite: isFavorite(card),
                                        quantity: quantity(card),
                                        onToggleFavorite: { toggleFavorite(card) },
                                        isSelected: false,
                                        selectionMode: false,
                                        onToggleSelection: {}
                                    )
                                }
                                .buttonStyle(ListPressableLinkStyle())
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .simultaneousGesture(
                                    LongPressGesture(minimumDuration: 0.35)
                                        .onEnded { _ in startSelectionAndSelect(card) }
                                )
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    Button { quickEditCard = card } label: {
                                        Label("Modifier", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button { toggleFavorite(card) } label: {
                                        Label(isFavorite(card) ? "Unfavorite" : "Favori",
                                              systemImage: isFavorite(card) ? "star.slash" : "star.fill")
                                    }
                                    .tint(.yellow)

                                    Button(role: .destructive) {
                                        pendingDeleteItems = [card]
                                        showDeleteConfirm = true
                                        Haptics.warning()
                                    } label: {
                                        Label("Supprimer", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Button {
                        toggleSection(section.key)
                        Haptics.light()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: expandedSectionKeys.contains(section.key) ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.key)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                if section.totalValueCAD > 0 {
                                    Text("≈ \(Money.moneyCAD(section.totalValueCAD))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Text("\(section.items.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous).fill(Color(.secondarySystemGroupedBackground))
                                )
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Sections builder

    private struct CollectionSection: Identifiable {
        let id: String
        let key: String
        let items: [CardItem]
        let totalValueCAD: Double
    }

    private func buildSections(
        from items: [CardItem],
        groupBy: GroupByOption,
        sectionSort: SectionSortOption
    ) -> [CollectionSection] {

        let dict: [String: [CardItem]] = Dictionary(grouping: items) { card in
            switch groupBy {
            case .none:
                return "Toutes"
            case .year:
                let v = (card.cardYear ?? "").trimmedLocal
                return v.isEmpty ? "Sans année" : v
            case .set:
                let v = (card.setName ?? "").trimmedLocal
                return v.isEmpty ? "Sans set" : v
            case .player:
                let v = (card.playerName ?? "").trimmedLocal
                return v.isEmpty ? "Sans joueur" : v
            }
        }

        var sections: [CollectionSection] = dict.map { (k, list) in
            CollectionSection(
                id: k,
                key: k,
                items: list,
                totalValueCAD: totalEstimatedValue(of: list)
            )
        }

        sections.sort { a, b in
            let aSans = a.key.lowercased().hasPrefix("sans ")
            let bSans = b.key.lowercased().hasPrefix("sans ")
            if aSans != bSans { return bSans == false }

            switch sectionSort {
            case .valueHigh:
                if a.totalValueCAD != b.totalValueCAD { return a.totalValueCAD > b.totalValueCAD }
                return sortSectionKey(a.key, b.key, groupBy: groupBy)
            case .alphaAZ:
                return a.key.localizedCaseInsensitiveCompare(b.key) == .orderedAscending
            case .alphaZA:
                return a.key.localizedCaseInsensitiveCompare(b.key) == .orderedDescending
            }
        }

        return sections
    }

    private func sortSectionKey(_ a: String, _ b: String, groupBy: GroupByOption) -> Bool {
        let aSans = a.lowercased().hasPrefix("sans ")
        let bSans = b.lowercased().hasPrefix("sans ")
        if aSans != bSans { return bSans == false }

        switch groupBy {
        case .year:
            let ai = Int(a) ?? Int(a.filter(\.isNumber)) ?? -1
            let bi = Int(b) ?? Int(b.filter(\.isNumber)) ?? -1
            if ai != -1 || bi != -1 { return ai > bi }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        case .set, .player, .none:
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    // MARK: - Expand / collapse

    private func rebuildExpandedKeys() {
        guard groupBy != .none else {
            expandedSectionKeys = []
            return
        }
        let items = filteredSortedAndFilteredCards
        let sections = buildSections(from: items, groupBy: groupBy, sectionSort: sectionSort)
        expandedSectionKeys = Set(sections.map { $0.key })
    }

    private func toggleSection(_ key: String) {
        if expandedSectionKeys.contains(key) { expandedSectionKeys.remove(key) }
        else { expandedSectionKeys.insert(key) }
    }

    private func bindingForSection(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expandedSectionKeys.contains(key) },
            set: { newValue in
                if newValue { expandedSectionKeys.insert(key) }
                else { expandedSectionKeys.remove(key) }
            }
        )
    }

    private func groupedAllExpanded(keys: Set<String>) -> Bool {
        guard !keys.isEmpty else { return false }
        return keys.isSubset(of: expandedSectionKeys)
    }

    private func toggleAllSections(keys: Set<String>) {
        guard !keys.isEmpty else { return }
        if keys.isSubset(of: expandedSectionKeys) {
            expandedSectionKeys.subtract(keys)
            Haptics.light()
        } else {
            expandedSectionKeys.formUnion(keys)
            Haptics.light()
        }
    }

    // MARK: - Empty message

    private var emptyMessage: String {
        let q = searchText.trimmedLocal
        if cards.isEmpty { return "Aucune carte pour le moment. Appuie sur + pour en ajouter une." }

        if q.isEmpty {
            if filter == .all { return "Aucune carte à afficher." }
            if filter.isMissingFieldFilter { return "Aucune carte ne correspond à “\(filter.rawValue)”. 🎉" }
            return "Aucune carte ne correspond à ce filtre."
        }

        return "Aucun résultat pour “\(q)”."
    }

    // MARK: - Search + Filter + Sort

    private var filteredSortedAndFilteredCards: [CardItem] {
        let q = searchText.trimmedLocal.lowercased()

        let searched: [CardItem]
        if q.isEmpty {
            searched = cards
        } else {
            searched = cards.filter { card in searchableText(for: card).contains(q) }
        }

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

            // ✅ Champs manquants
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
        if let v = card.acquisitionSource { parts.append(v) }
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
        items.reduce(0) { $0 + CollectionQuantityStore.quantity(id: $1.id) }
    }

    // MARK: - Delete (sync Marketplace + clean favorites + quantity)

    private func deleteItemsNow(_ items: [CardItem]) {
        Task {
            for card in items {
                await marketplace.endListingIfExistsForDeletedCard(cardItemId: card.id.uuidString)
            }

            await MainActor.run {
                for card in items {
                    FavoritesStore.clear(id: card.id)
                    CollectionQuantityStore.clear(id: card.id)
                    modelContext.delete(card)
                }
                do {
                    try modelContext.save()
                    favoritesTick += 1
                    quantityTick += 1
                    Haptics.success()
                    exitSelectionMode()
                } catch {
                    uiErrorText = error.localizedDescription
                    Haptics.error()
                }
            }
        }
    }
}

// MARK: - Mini header

private struct CollectionMiniHeader: View {
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
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ma collection")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Text("\(count) carte\(count > 1 ? "s" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if totalCopies != count {
                        Text("\(totalCopies) exemplaire\(totalCopies > 1 ? "s" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if totalValueCAD > 0 {
                        Text("≈ \(Money.moneyCAD(totalValueCAD))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Chip(text: sortLabel, systemImage: "arrow.up.arrow.down")

                if isGrouped {
                    Chip(text: "Par \(groupLabel.lowercased())", systemImage: "square.grid.2x2.fill")
                    Chip(text: sectionSortLabel, systemImage: "list.bullet")
                    if sectionCount > 0 {
                        ToggleAllChip(
                            isExpanded: groupAllExpanded,
                            sectionCount: sectionCount,
                            onTap: onToggleAll
                        )
                    }
                }

                if let missingFilterLabel {
                    Chip(text: missingFilterLabel, systemImage: "exclamationmark.circle")
                }

                if isFavoritesFilterOn { Chip(text: "Favoris", systemImage: "star.fill") }
                if hasActiveFilter { Chip(text: "Filtré", systemImage: "line.3.horizontal.decrease.circle.fill") }
                if hasActiveSearch { Chip(text: "Recherche", systemImage: "magnifyingglass") }

                if hasActiveFilter || hasActiveSearch || isGrouped || isFavoritesFilterOn || sortLabel != MyCollectionInnerView.SortOption.newest.rawValue {
                    Button { onReset() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private struct Chip: View {
        let text: String
        let systemImage: String

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(text).lineLimit(1)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        }
    }

    private struct ToggleAllChip: View {
        let isExpanded: Bool
        let sectionCount: Int
        let onTap: () -> Void

        var body: some View {
            Button { onTap() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    Text(isExpanded ? "Tout fermer (\(sectionCount))" : "Tout ouvrir (\(sectionCount))").lineLimit(1)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Section card (Grid grouped)

private struct SectionCard<Content: View>: View {
    let title: String
    let count: Int
    let valueCAD: Double
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    init(
        title: String,
        count: Int,
        valueCAD: Double,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.count = count
        self.valueCAD = valueCAD
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { isExpanded.toggle(); Haptics.light() } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if valueCAD > 0 {
                            Text("≈ \(Money.moneyCAD(valueCAD))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule(style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, 10).padding(.bottom, 8)
                content
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.systemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 1))
    }
}

// MARK: - Grid Card

private struct CollectionGridCard: View {
    let card: CardItem
    let isFavorite: Bool
    let quantity: Int
    let onToggleFavorite: () -> Void

    let isSelected: Bool
    let selectionMode: Bool
    let onToggleSelection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            SlabLocalThumb(data: card.frontImageData, height: 200)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        if selectionMode {
                            Button { onToggleSelection() } label: {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(8)
                                    .background(Circle().fill(Color(.systemBackground).opacity(0.9)))
                                    .overlay(Circle().stroke(Color.black.opacity(0.10), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button { onToggleFavorite() } label: {
                                Image(systemName: isFavorite ? "star.fill" : "star")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                                    .padding(8)
                                    .background(Circle().fill(Color(.systemBackground).opacity(0.9)))
                                    .overlay(Circle().stroke(Color.black.opacity(0.10), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 6)
                    .padding(.top, 6)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 6) {
                        if quantity > 1 {
                            QuantityPill(text: "x\(quantity)")
                        }
                        if let label = card.gradingLabel {
                            GradingOverlayBadge(label: label, compact: false)
                        }
                    }
                    .padding(.trailing, 6)
                    .padding(.top, 6)
                }

            Text(card.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let notes = card.notes?.trimmedLocal, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let price = card.estimatedPriceCAD, price > 0 {
                Text("≈ \(Money.moneyCAD(price))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
    }

    private struct QuantityPill: View {
        let text: String
        var body: some View {
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                .overlay(Capsule(style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 1))
        }
    }
}

// MARK: - List Row

private struct CollectionListRow: View {
    let card: CardItem
    let isFavorite: Bool
    let quantity: Int
    let onToggleFavorite: () -> Void

    let isSelected: Bool
    let selectionMode: Bool
    let onToggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {

            SlabLocalThumb(data: card.frontImageData, height: 72)
                .frame(width: 52)
                .overlay(alignment: .topTrailing) {
                    if let label = card.gradingLabel {
                        GradingOverlayBadge(label: label, compact: true)
                            .offset(x: 8, y: -8)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {

                HStack(spacing: 6) {
                    Text(card.title)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if quantity > 1 {
                        Text("x\(quantity)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule(style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                    }

                    if isFavorite && !selectionMode {
                        Image(systemName: "star.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.yellow)
                    }
                }

                if let notes = card.notes?.trimmedLocal, !notes.isEmpty {
                    Text(notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let price = card.estimatedPriceCAD, price > 0 {
                    Text("≈ \(Money.moneyCAD(price))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if selectionMode {
                Button { onToggleSelection() } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? .blue : .secondary)
                }
                .buttonStyle(.plain)
            } else {
                Button { onToggleFavorite() } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Slab thumb

private struct SlabLocalThumb: View {
    let data: Data?
    let height: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))

            if let data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.secondary.opacity(0.10))
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 1)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Button styles

private struct GridPressableLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .opacity(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: configuration.isPressed)
    }
}

private struct ListPressableLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? Color.blue.opacity(0.06) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.995 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.90), value: configuration.isPressed)
    }
}

// MARK: - Money formatter

private enum Money {
    static func moneyCAD(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CAD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f $ CAD", value)
    }
}

// MARK: - ✅ Haptics

private enum Haptics {
    static func light() {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred()
    }

    static func medium() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        gen.impactOccurred()
    }

    static func selectionStart() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        gen.impactOccurred(intensity: 0.9)
    }

    static func selectionToggleOn() {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred(intensity: 0.8)
    }

    static func selectionToggleOff() {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred(intensity: 0.6)
    }

    static func success() {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.success)
    }

    static func warning() {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.warning)
    }

    static func error() {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.error)
    }
}

// MARK: - ✅ CollectionQuantityStore (UserDefaults)

private enum CollectionQuantityStore {
    private static let key = "collection.quantityByCardId" // [String: Int]

    static func quantity(id: UUID) -> Int {
        let dict = load()
        let v = dict[id.uuidString] ?? 1
        return max(1, v)
    }

    static func setQuantity(_ quantity: Int, id: UUID) {
        var dict = load()
        dict[id.uuidString] = max(1, quantity)
        save(dict)
    }

    static func clear(id: UUID) {
        var dict = load()
        dict.removeValue(forKey: id.uuidString)
        save(dict)
    }

    private static func load() -> [String: Int] {
        let obj = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        var out: [String: Int] = [:]
        for (k, v) in obj {
            if let i = v as? Int { out[k] = i }
            else if let n = v as? NSNumber { out[k] = n.intValue }
        }
        return out
    }

    private static func save(_ dict: [String: Int]) {
        UserDefaults.standard.set(dict, forKey: key)
    }
}

// MARK: - Helpers

private extension String {
    var trimmedLocal: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
