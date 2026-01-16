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

    /// ✅ User courant (pour filtrer SwiftData)
    private var uid: String?

    init(modelContext: ModelContext, uid: String?) {
        self.modelContext = modelContext
        self.uid = uid
        refresh()
    }

    // MARK: - User

    /// ✅ À appeler quand l’utilisateur se connecte / se déconnecte
    func setUser(uid: String?) {
        self.uid = uid
        refresh()
    }

    // MARK: - Read

    func refresh() {
        lastError = nil

        // ✅ Si pas connecté: on ne montre rien
        guard let uid, !uid.isEmpty else {
            myCards = []
            return
        }

        do {
            let predicate = #Predicate<CardItem> { $0.ownerId == uid }

            let descriptor = FetchDescriptor<CardItem>(
                predicate: predicate,
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

        guard let uid, !uid.isEmpty else {
            lastError = "Tu dois être connecté pour ajouter une carte."
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            lastError = "Le titre ne peut pas être vide."
            return
        }

        // ✅ IMPORTANT: ownerId
        let card = CardItem(
            ownerId: uid,
            title: trimmedTitle,
            notes: notes,
            frontImageData: frontImageData
        )

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

        guard let uid, !uid.isEmpty else {
            lastError = "Tu dois être connecté pour modifier une carte."
            return
        }

        // ✅ Sécurité: empêche de modifier une carte d’un autre user
        guard card.ownerId == uid else {
            lastError = "Impossible : cette carte n’appartient pas à cet utilisateur."
            return
        }

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

        guard let uid, !uid.isEmpty else {
            lastError = "Tu dois être connecté pour supprimer une carte."
            return
        }

        // ✅ Sécurité: empêche de supprimer une carte d’un autre user
        guard card.ownerId == uid else {
            lastError = "Impossible : cette carte n’appartient pas à cet utilisateur."
            return
        }

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

