//
//  ContentView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import SwiftData
import UIKit
import PhotosUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var session: SessionStore

    @Query(sort: \CardItem.createdAt, order: .reverse)
    private var cards: [CardItem]

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

    // ✅ Confirmation suppression
    @State private var pendingDeleteItems: [CardItem] = []
    @State private var showDeleteConfirm = false

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

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .newest: return "clock.arrow.circlepath"
            case .oldest: return "clock"
            case .titleAZ: return "text.line.first.and.arrowtriangle.forward"
            case .titleZA: return "text.line.last.and.arrowtriangle.forward"
            case .valueHigh: return "arrow.down.circle"
            case .valueLow: return "arrow.up.circle"
            }
        }
    }

    enum FilterOption: String, CaseIterable, Identifiable {
        case all = "Toutes"
        case withValue = "Avec valeur"
        case withoutValue = "Sans valeur"
        case withNotes = "Avec notes"
        case withoutNotes = "Sans notes"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .all: return "line.3.horizontal.decrease.circle"
            case .withValue: return "dollarsign.circle"
            case .withoutValue: return "dollarsign.circle.fill"
            case .withNotes: return "note.text"
            case .withoutNotes: return "note.text.badge.plus"
            }
        }
    }

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
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAddSheet = true } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(true)
                        .accessibilityLabel("Ajouter une carte")
                    }
                }

            } else {

                // ✅ Connecté
                let items = filteredSortedAndFilteredCards
                let totalValue = totalEstimatedValue(of: items)

                // ✅ Si regroupé: sections calculées une fois (header + UI)
                let groupedSections: [CollectionSection] = {
                    if groupBy == .none { return [] }
                    return buildSections(from: items, groupBy: groupBy, sectionSort: sectionSort)
                }()

                let sectionCount = groupedSections.count
                let allExpanded = groupedAllExpanded(keys: Set(groupedSections.map { $0.key }))

                Group {
                    if items.isEmpty {
                        ContentUnavailableView(
                            "Ma collection",
                            systemImage: "rectangle.stack",
                            description: Text(emptyMessage)
                        )
                    } else {
                        VStack(spacing: 0) {

                            CollectionMiniHeader(
                                count: items.count,
                                totalValueCAD: totalValue,
                                hasActiveFilter: filter != .all,
                                hasActiveSearch: !searchText.trimmedLocal.isEmpty,
                                sortLabel: sort.rawValue,
                                groupLabel: groupBy.rawValue,
                                isGrouped: groupBy != .none,
                                sectionSortLabel: sectionSort.rawValue,
                                sectionCount: sectionCount,
                                groupAllExpanded: allExpanded,
                                onToggleAll: {
                                    toggleAllSections(keys: Set(groupedSections.map { $0.key }))
                                },
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
                    }
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: "Rechercher une carte…")
                .toolbar {

                    // ✅ Filtrer
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Filtrer", selection: $filter) {
                                ForEach(FilterOption.allCases) { opt in
                                    Label(opt.rawValue, systemImage: opt.systemImage)
                                        .tag(opt)
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

                    // ✅ Trier items (cartes)
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Trier", selection: $sort) {
                                ForEach(SortOption.allCases) { opt in
                                    Label(opt.rawValue, systemImage: opt.systemImage)
                                        .tag(opt)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .accessibilityLabel("Trier")
                    }

                    // ✅ Regrouper + Tri sections
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Regrouper par", selection: $groupBy) {
                                ForEach(GroupByOption.allCases) { opt in
                                    Label(opt.rawValue, systemImage: opt.systemImage)
                                        .tag(opt)
                                }
                            }

                            if groupBy != .none {
                                Divider()

                                Picker("Trier les sections", selection: $sectionSort) {
                                    ForEach(SectionSortOption.allCases) { opt in
                                        Label(opt.rawValue, systemImage: opt.systemImage)
                                            .tag(opt)
                                    }
                                }
                            }

                            if groupBy != .none {
                                Divider()
                                Button {
                                    groupBy = .none
                                } label: {
                                    Label("Désactiver le regroupement", systemImage: "xmark.circle")
                                }
                            }
                        } label: {
                            Image(systemName: groupBy == .none ? "square.grid.2x2" : "square.grid.2x2.fill")
                        }
                        .accessibilityLabel("Regrouper")
                    }

                    // ✅ Ajouter
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAddSheet = true } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Ajouter une carte")
                    }
                }
                .onChange(of: groupBy) { _, _ in
                    persistUIState()
                    rebuildExpandedKeys()
                }
                .onChange(of: sectionSort) { _, _ in
                    persistUIState()
                }
                .onChange(of: searchText) { _, _ in
                    persistUIState()
                    if groupBy != .none { rebuildExpandedKeys() }
                }
                .onChange(of: viewMode) { _, _ in
                    persistUIState()
                }
                .onChange(of: sort) { _, _ in
                    persistUIState()
                }
                .onChange(of: filter) { _, _ in
                    persistUIState()
                }
                .sheet(isPresented: $showAddSheet) {
                    AddCardView()
                }
                // ✅ Quick Edit sheet
                .sheet(item: $quickEditCard) { card in
                    CardQuickEditView(card: card)
                }
                .alert("Erreur", isPresented: Binding(
                    get: { uiErrorText != nil },
                    set: { if !$0 { uiErrorText = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(uiErrorText ?? "")
                }
                .alert("Supprimer", isPresented: $showDeleteConfirm) {
                    Button("Annuler", role: .cancel) { pendingDeleteItems = [] }
                    Button("Supprimer", role: .destructive) {
                        let toDelete = pendingDeleteItems
                        pendingDeleteItems = []
                        deleteItemsNow(toDelete)
                    }
                } message: {
                    let count = pendingDeleteItems.count
                    Text(count <= 1
                         ? "Supprimer cette carte? Cette action est irréversible."
                         : "Supprimer ces \(count) cartes? Cette action est irréversible.")
                }
            }
        }
        .onAppear {
            restoreUIState()
            if groupBy != .none {
                rebuildExpandedKeys()
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

        if let m = ViewMode(rawValue: storedViewModeRaw) { viewMode = m } else { viewMode = .grid }
        if let s = SortOption(rawValue: storedSortRaw) { sort = s } else { sort = .newest }
        if let f = FilterOption(rawValue: storedFilterRaw) { filter = f } else { filter = .all }
        if let g = GroupByOption(rawValue: storedGroupByRaw) { groupBy = g } else { groupBy = .none }
        if let ss = SectionSortOption(rawValue: storedSectionSortRaw) { sectionSort = ss } else { sectionSort = .valueHigh }
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
                    NavigationLink {
                        CardDetailView(card: card)
                    } label: {
                        CollectionGridCard(card: card)
                    }
                    .buttonStyle(GridPressableLinkStyle())
                    .contextMenu {
                        Button {
                            quickEditCard = card
                        } label: {
                            Label("Modifier", systemImage: "pencil")
                        }

                        Divider()

                        Button(role: .destructive) {
                            pendingDeleteItems = [card]
                            showDeleteConfirm = true
                        } label: {
                            Label("Supprimer", systemImage: "trash")
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
                NavigationLink {
                    CardDetailView(card: card)
                } label: {
                    CollectionListRow(card: card)
                }
                .buttonStyle(ListPressableLinkStyle())
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        quickEditCard = card
                    } label: {
                        Label("Modifier", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        pendingDeleteItems = [card]
                        showDeleteConfirm = true
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                let toDelete = offsets.compactMap { idx in
                    items.indices.contains(idx) ? items[idx] : nil
                }
                guard !toDelete.isEmpty else { return }
                pendingDeleteItems = toDelete
                showDeleteConfirm = true
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
                                NavigationLink {
                                    CardDetailView(card: card)
                                } label: {
                                    CollectionGridCard(card: card)
                                }
                                .buttonStyle(GridPressableLinkStyle())
                                .contextMenu {
                                    Button {
                                        quickEditCard = card
                                    } label: {
                                        Label("Modifier", systemImage: "pencil")
                                    }

                                    Divider()

                                    Button(role: .destructive) {
                                        pendingDeleteItems = [card]
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Supprimer", systemImage: "trash")
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
                            NavigationLink {
                                CardDetailView(card: card)
                            } label: {
                                CollectionListRow(card: card)
                            }
                            .buttonStyle(ListPressableLinkStyle())
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    quickEditCard = card
                                } label: {
                                    Label("Modifier", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    pendingDeleteItems = [card]
                                    showDeleteConfirm = true
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button {
                                    quickEditCard = card
                                } label: {
                                    Label("Modifier", systemImage: "pencil")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    pendingDeleteItems = [card]
                                    showDeleteConfirm = true
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Button {
                        toggleSection(section.key)
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
            if aSans != bSans { return bSans }

            switch sectionSort {
            case .valueHigh:
                if a.totalValueCAD != b.totalValueCAD {
                    return a.totalValueCAD > b.totalValueCAD
                }
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
        if aSans != bSans { return bSans }

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
        if expandedSectionKeys.contains(key) {
            expandedSectionKeys.remove(key)
        } else {
            expandedSectionKeys.insert(key)
        }
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
        } else {
            expandedSectionKeys.formUnion(keys)
        }
    }

    // MARK: - Empty message

    private var emptyMessage: String {
        let q = searchText.trimmedLocal
        if q.isEmpty { return "Aucune carte pour le moment. Appuie sur + pour en ajouter une." }
        return "Aucun résultat pour “\(q)”."
    }

    // MARK: - Search + Filter + Sort

    private var filteredSortedAndFilteredCards: [CardItem] {
        let q = searchText.trimmedLocal.lowercased()

        let searched: [CardItem]
        if q.isEmpty {
            searched = cards
        } else {
            searched = cards.filter { card in
                searchableText(for: card).contains(q)
            }
        }

        let filtered: [CardItem] = searched.filter { card in
            switch filter {
            case .all:
                return true
            case .withValue:
                return (card.estimatedPriceCAD ?? 0) > 0
            case .withoutValue:
                return (card.estimatedPriceCAD ?? 0) <= 0
            case .withNotes:
                return !(card.notes?.trimmedLocal.isEmpty ?? true)
            case .withoutNotes:
                return (card.notes?.trimmedLocal.isEmpty ?? true)
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

    // MARK: - Total value

    private func totalEstimatedValue(of items: [CardItem]) -> Double {
        items.reduce(0) { partial, card in
            partial + max(0, card.estimatedPriceCAD ?? 0)
        }
    }

    // MARK: - Delete (sync Marketplace)

    private func deleteItemsNow(_ items: [CardItem]) {
        Task {
            for card in items {
                await marketplace.endListingIfExistsForDeletedCard(
                    cardItemId: card.id.uuidString
                )
            }

            await MainActor.run {
                for card in items {
                    modelContext.delete(card)
                }
                do {
                    try modelContext.save()
                } catch {
                    uiErrorText = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Mini header

private struct CollectionMiniHeader: View {
    let count: Int
    let totalValueCAD: Double
    let hasActiveFilter: Bool
    let hasActiveSearch: Bool
    let sortLabel: String
    let groupLabel: String
    let isGrouped: Bool
    let sectionSortLabel: String

    let sectionCount: Int
    let groupAllExpanded: Bool
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

                if hasActiveFilter {
                    Chip(text: "Filtré", systemImage: "line.3.horizontal.decrease.circle.fill")
                }

                if hasActiveSearch {
                    Chip(text: "Recherche", systemImage: "magnifyingglass")
                }

                if hasActiveFilter || hasActiveSearch || isGrouped || sortLabel != ContentView.SortOption.newest.rawValue {
                    Button { onReset() } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Réinitialiser")
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
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    private struct ToggleAllChip: View {
        let isExpanded: Bool
        let sectionCount: Int
        let onTap: () -> Void

        var body: some View {
            Button {
                onTap()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    Text(isExpanded ? "Tout fermer (\(sectionCount))" : "Tout ouvrir (\(sectionCount))")
                        .lineLimit(1)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Tout fermer" : "Tout ouvrir")
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

            Button {
                isExpanded.toggle()
            } label: {
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
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)

                content
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Grid Card

private struct CollectionGridCard: View {
    let card: CardItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            SlabLocalThumb(data: card.frontImageData, height: 200)
                .overlay(alignment: .topTrailing) {
                    if let label = card.gradingLabel {
                        GradingOverlayBadge(label: label, compact: false)
                            .offset(x: -4, y: 6)
                            .padding(.trailing, 2)
                    }
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
}

// MARK: - List Row

private struct CollectionListRow: View {
    let card: CardItem

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
                Text(card.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

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

// MARK: - Helpers

private extension String {
    var trimmedLocal: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

