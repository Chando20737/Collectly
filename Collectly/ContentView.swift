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
import FirebaseAuth

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var session: SessionStore

    @Query(sort: \CardItem.createdAt, order: .reverse)
    private var cards: [CardItem]

    @State private var searchText: String = ""
    @State private var viewMode: ViewMode = .grid
    @State private var sort: SortOption = .newest
    @State private var filter: FilterOption = .all

    @State private var uiErrorText: String? = nil
    @State private var showAddSheet = false

    private let marketplace = MarketplaceService()

    enum ViewMode: String, CaseIterable, Identifiable {
        case grid = "Grille"
        case list = "Liste"
        var id: String { rawValue }
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

                    // ✅ + visible mais désactivé
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
                                hasActiveFilter: filter != .all,
                                sortLabel: sort.rawValue
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

                            if viewMode == .grid {
                                collectionGrid(items)
                            } else {
                                collectionList(items)
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

                    // ✅ Trier
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

                    // ✅ Ajouter
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAddSheet = true } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Ajouter une carte")
                    }
                }
                .sheet(isPresented: $showAddSheet) {
                    AddCardView()
                }
                .alert("Erreur", isPresented: Binding(
                    get: { uiErrorText != nil },
                    set: { if !$0 { uiErrorText = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(uiErrorText ?? "")
                }
            }
        }
    }

    // MARK: - Grid

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
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
    }

    // MARK: - List

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
            }
            .onDelete { offsets in
                deleteCards(offsets, in: items)
            }
        }
        .listStyle(.plain)
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

    // MARK: - Delete (sync Marketplace)

    private func deleteCards(_ offsets: IndexSet, in currentList: [CardItem]) {
        let toDelete = offsets.compactMap { idx in
            currentList.indices.contains(idx) ? currentList[idx] : nil
        }

        Task {
            for card in toDelete {
                await marketplace.endListingIfExistsForDeletedCard(
                    cardItemId: card.id.uuidString
                )
            }

            await MainActor.run {
                for card in toDelete {
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
    let hasActiveFilter: Bool
    let sortLabel: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ma collection")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("\(count) carte\(count > 1 ? "s" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Chip(text: sortLabel, systemImage: "arrow.up.arrow.down")

                if hasActiveFilter {
                    Chip(text: "Filtré", systemImage: "line.3.horizontal.decrease.circle.fill")
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

            if let price = card.estimatedPriceCAD {
                Text("≈ \(Self.moneyCAD(price))")
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

    private static func moneyCAD(_ value: Double) -> String {
        String(format: "%.2f $ CAD", value)
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

                if let price = card.estimatedPriceCAD {
                    Text("≈ \(Self.moneyCAD(price))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private static func moneyCAD(_ value: Double) -> String {
        String(format: "%.2f $ CAD", value)
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

// MARK: - Helpers

private extension String {
    var trimmedLocal: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension CardItem {
    var gradingLabel: String? {
        let g = (gradeValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let c = (gradingCompany ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { return nil }
        return c.isEmpty ? g : "\(c) \(g)"
    }
}
