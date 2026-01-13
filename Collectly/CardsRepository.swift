//
//  CardsRepository.swift
//  Collectly
//
//  Repository LOCAL (SwiftData) pour CardItem
//

import Foundation
import Combine
import SwiftData

@MainActor
final class CardsRepository: ObservableObject {

    @Published private(set) var myCards: [CardItem] = []
    @Published private(set) var lastError: String? = nil

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        refresh()
    }

    // MARK: - Read

    func refresh() {
        lastError = nil
        do {
            let descriptor = FetchDescriptor<CardItem>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            myCards = try modelContext.fetch(descriptor)
        } catch {
            lastError = "Erreur SwiftData (fetch): \(error.localizedDescription)"
            myCards = []
        }
    }

    // MARK: - Create

    func addCard(
        title: String,
        notes: String? = nil,
        frontImageData: Data? = nil
    ) {
        lastError = nil

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            lastError = "Le titre ne peut pas être vide."
            return
        }

        let card = CardItem(title: trimmedTitle, notes: notes, frontImageData: frontImageData)
        modelContext.insert(card)
        saveAndRefresh(context: "save add")
    }

    // MARK: - Update

    func updateCard(
        _ card: CardItem,
        title: String,
        notes: String? = nil,
        frontImageData: Data? = nil
    ) {
        lastError = nil

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            lastError = "Le titre ne peut pas être vide."
            return
        }

        card.title = trimmedTitle
        card.notes = notes
        card.frontImageData = frontImageData

        saveAndRefresh(context: "save update")
    }

    // MARK: - Delete

    func deleteCard(_ card: CardItem) {
        lastError = nil
        modelContext.delete(card)
        saveAndRefresh(context: "save delete")
    }

    // MARK: - Private

    private func saveAndRefresh(context: String) {
        do {
            try modelContext.save()
            refresh()
        } catch {
            lastError = "Erreur SwiftData (\(context)): \(error.localizedDescription)"
        }
    }
}

