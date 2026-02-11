// FirebaseSync.swift
// Synchronisation Firebase → SwiftData
// Télécharge toutes les cartes de l'utilisateur depuis Firebase et les sauvegarde localement

import Foundation
import SwiftUI
import SwiftData
import Combine
import FirebaseFirestore
import FirebaseStorage

@MainActor
class FirebaseSync: ObservableObject {
    
    @Published var isSyncing = false
    @Published var syncProgress: String = ""
    @Published var syncError: String?
    
    private let db = Firestore.firestore()
    private let storage = Storage.storage()
    
    // MARK: - Public API
    
    /// Synchronise toutes les cartes depuis Firebase vers SwiftData
    /// À appeler au premier lancement après installation
    func syncFromFirebase(userId: String, modelContext: ModelContext) async {
        guard !isSyncing else {
            print("⚠️ Sync already in progress")
            return
        }
        
        isSyncing = true
        syncError = nil
        syncProgress = "Récupération des cartes..."
        
        do {
            // 1. Récupérer toutes les cartes de cet utilisateur depuis Firebase
            print("📥 Fetching scans from Firebase for user: \(userId)")
            
            let snapshot = try await db.collection("scans")
                .whereField("ownerId", isEqualTo: userId)
                .order(by: "timestamp", descending: true)
                .getDocuments()
            
            print("📚 Found \(snapshot.documents.count) scans in Firebase")
            
            guard !snapshot.documents.isEmpty else {
                syncProgress = "Aucune carte à synchroniser"
                isSyncing = false
                try? await Task.sleep(for: .seconds(2))
                syncProgress = ""
                return
            }
            
            // 2. Vérifier quelles cartes existent déjà en local
            let existingCards = try modelContext.fetch(FetchDescriptor<CardItem>())
            let existingFirebaseIds = Set(existingCards.compactMap { $0.firebaseId })
            
            print("📦 Found \(existingCards.count) existing cards in SwiftData")
            
            var downloadedCount = 0
            var skippedCount = 0
            var errorCount = 0
            
            // 3. Télécharger chaque carte
            for (index, document) in snapshot.documents.enumerated() {
                let scanId = document.documentID
                
                // Skip si déjà téléchargée
                if existingFirebaseIds.contains(scanId) {
                    skippedCount += 1
                    print("⏭️  [\(index + 1)/\(snapshot.documents.count)] Skip: \(scanId) (already exists)")
                    continue
                }
                
                syncProgress = "Téléchargement \(index + 1)/\(snapshot.documents.count)..."
                
                do {
                    let card = try await downloadCard(from: document, userId: userId)
                    modelContext.insert(card)
                    downloadedCount += 1
                    print("✅ [\(index + 1)/\(snapshot.documents.count)] Downloaded: \(card.title)")
                } catch {
                    errorCount += 1
                    print("❌ [\(index + 1)/\(snapshot.documents.count)] Error downloading \(scanId): \(error)")
                }
            }
            
            // 4. Sauvegarder tout
            try modelContext.save()
            
            print("🎉 Sync complete!")
            print("   ✅ Downloaded: \(downloadedCount)")
            print("   ⏭️  Skipped: \(skippedCount)")
            print("   ❌ Errors: \(errorCount)")
            
            syncProgress = "✅ \(downloadedCount) cartes synchronisées"
            
            // Effacer le message après 3 secondes
            try? await Task.sleep(for: .seconds(3))
            syncProgress = ""
            
        } catch {
            print("❌ Sync failed: \(error)")
            syncError = "Erreur de synchronisation: \(error.localizedDescription)"
            syncProgress = ""
        }
        
        isSyncing = false
    }
    
    // MARK: - Private Helpers
    
    private func downloadCard(from document: QueryDocumentSnapshot, userId: String) async throws -> CardItem {
        let data = document.data()
        let scanId = document.documentID
        
        // Extraire metadata
        let playerName = data["playerName"] as? String ?? ""
        let cardNumber = data["cardNumber"] as? String ?? ""
        let setName = data["setName"] as? String ?? ""
        let year = data["year"] as? String ?? ""
        let company = data["company"] as? String ?? ""
        let frontUrl = data["frontUrl"] as? String ?? ""
        let backUrl = data["backUrl"] as? String ?? ""
        
        // Construire le titre
        let title = buildTitle(playerName: playerName, cardNumber: cardNumber, setName: setName, year: year)
        
        // Télécharger les images
        print("   📥 Downloading images for \(title)...")
        
        let frontImageData: Data?
        if !frontUrl.isEmpty, let url = URL(string: frontUrl) {
            frontImageData = try? await downloadImage(from: url)
        } else {
            frontImageData = nil
        }
        
        let backImageData: Data?
        if !backUrl.isEmpty, let url = URL(string: backUrl) {
            backImageData = try? await downloadImage(from: url)
        } else {
            backImageData = nil
        }
        
        // Créer CardItem
        let card = CardItem(
            ownerId: userId,
            title: title,
            notes: nil,
            frontImageData: frontImageData,
            backImageData: backImageData,
            estimatedPriceCAD: nil,
            playerName: playerName.isEmpty ? nil : playerName.capitalized,
            cardYear: year.isEmpty ? nil : year,
            companyName: company.isEmpty ? nil : company,
            setName: setName.isEmpty ? nil : setName,
            cardNumber: cardNumber.isEmpty ? nil : cardNumber,
            firebaseId: scanId  // Important: lier à Firebase
        )
        
        return card
    }
    
    private func downloadImage(from url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
    
    private func buildTitle(playerName: String, cardNumber: String, setName: String, year: String) -> String {
        var parts: [String] = []
        
        if !playerName.isEmpty {
            parts.append(playerName.capitalized)
        }
        
        if !cardNumber.isEmpty {
            parts.append(cardNumber)
        }
        
        if !setName.isEmpty {
            parts.append(setName)
        }
        
        if !year.isEmpty {
            parts.append("(\(year))")
        }
        
        return parts.isEmpty ? "Carte sans titre" : parts.joined(separator: " ")
    }
}
