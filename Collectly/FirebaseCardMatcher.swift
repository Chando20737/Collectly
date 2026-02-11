import Foundation
import UIKit
import Vision
import FirebaseFirestore
import FirebaseStorage

/// Client-side card matching using Firebase data and Vision Framework
class FirebaseCardMatcher {
    
    static let shared = FirebaseCardMatcher()
    
    private let db = Firestore.firestore()
    private let storage = Storage.storage()
    
    // Cache pour éviter de re-télécharger les mêmes images
    private var imageCache: [String: UIImage] = [:]
    
    private init() {}
    
    // MARK: - Public API
    
    /// Trouve les cartes similaires dans Firebase
    /// - Parameters:
    ///   - frontImage: L'image scannée à matcher
    ///   - limit: Nombre maximum de résultats (default: 3)
    ///   - ocrCardNumber: Numéro détecté par OCR pour filtrage intelligent (optionnel)
    ///   - year: Année détectée (ex: "2025-26") pour filtrage fallback
    ///   - setName: Nom du set (ex: "O-Pee-Chee") pour filtrage fallback
    ///   - company: Compagnie (ex: "Upper Deck") pour filtrage fallback
    /// - Returns: Array de matches triés par similarité
    func findMatches(
        for frontImage: UIImage, 
        limit: Int = 3, 
        ocrCardNumber: String? = nil,
        year: String? = nil,
        setName: String? = nil,
        company: String? = nil
    ) async throws -> [CardMatch] {
        print("🔍 Starting Firebase card matching...")
        
        // 1. Extraire les features de l'image scannée
        guard let scannedFeatures = extractFeatures(from: frontImage) else {
            throw MatchError.featureExtractionFailed
        }
        
        print("✅ Extracted features from scanned image")
        
        // 2. Récupérer tous les scans depuis Firestore
        let scans = try await fetchAllScans()
        print("📚 Found \(scans.count) scans in Firebase")
        
        guard !scans.isEmpty else {
            return []
        }
        
        // 3. ⚡️ OPTIMISATION: Filtrer intelligemment
        let scansToTest: [FirebaseScan]
        
        if let ocrNumber = ocrCardNumber {
            // PRIORITÉ 1: Filtrer par numéro de carte
            let (prefix, number) = extractPrefixAndNumber(from: ocrNumber)
            
            if let detectedNum = number {
                let range = (detectedNum - 15)...(detectedNum + 15)
                scansToTest = scans.filter { scan in
                    let (scanPrefix, scanNum) = extractPrefixAndNumber(from: scan.cardNumber)
                    guard scanPrefix == prefix else { return false }
                    if let scanNum = scanNum {
                        return range.contains(scanNum)
                    }
                    return false
                }
                
                if !prefix.isEmpty {
                    print("🎯 Filtered to \(scansToTest.count) scans with prefix '\(prefix)' near #\(detectedNum)")
                } else {
                    print("🎯 Filtered to \(scansToTest.count) scans near #\(detectedNum)")
                }
                
                // Continue avec scansToTest (déjà filtré)
            } else {
                scansToTest = []
            }
        } else {
            scansToTest = []
        }
        
        // FALLBACK: Si pas assez de résultats avec numéro, filtrer par metadata
        let finalScansToTest: [FirebaseScan]
        if scansToTest.count < 5 {
            print("⚠️ Fallback: filtering by metadata (year/set/company)")
            
            let metadataFiltered = scans.filter { scan in
                var matches = 0
                var total = 0
                
                // Match année si disponible
                if let year = year, !year.isEmpty {
                    total += 1
                    if scan.year.lowercased().contains(year.lowercased()) || 
                       year.lowercased().contains(scan.year.lowercased()) {
                        matches += 1
                    }
                }
                
                // Match set si disponible
                if let setName = setName, !setName.isEmpty {
                    total += 1
                    let scanSet = scan.setName.lowercased()
                    let queryset = setName.lowercased()
                    if scanSet.contains(queryset) || queryset.contains(scanSet) {
                        matches += 1
                    }
                }
                
                // Match compagnie si disponible
                if let company = company, !company.isEmpty {
                    total += 1
                    if scan.company.lowercased().contains(company.lowercased()) ||
                       company.lowercased().contains(scan.company.lowercased()) {
                        matches += 1
                    }
                }
                
                // Garder si au moins 2/3 des critères matchent (ou si pas de critères)
                return total == 0 || matches >= max(1, total - 1)
            }
            
            print("🎯 Metadata filter: \(metadataFiltered.count) scans match year/set/company")
            
            // Si toujours trop peu, prendre tous les scans
            if metadataFiltered.count < 5 {
                print("⚠️ Still too few, testing all \(scans.count) scans")
                finalScansToTest = scans
            } else {
                finalScansToTest = metadataFiltered
            }
        } else {
            finalScansToTest = scansToTest
        }
        
        var visualMatches: [CardMatch] = []
        
        // 4. Comparer visuellement (en background)
        await withTaskGroup(of: CardMatch?.self) { group in
            for scan in finalScansToTest {
                group.addTask {
                    guard let candidateImage = await self.downloadImageAsync(from: scan.frontUrl) else {
                        return nil
                    }
                    
                    guard let candidateFeatures = self.extractFeatures(from: candidateImage) else {
                        return nil
                    }
                    
                    let visualSimilarity = self.compareFeatures(scannedFeatures, candidateFeatures)
                    
                    // Filtrer les mauvais matches immédiatement
                    guard visualSimilarity > 0.50 else {
                        return nil
                    }
                    
                    let match = CardMatch(
                        scanId: scan.scanId,
                        playerName: scan.playerName,
                        cardNumber: scan.cardNumber,
                        setName: scan.setName,
                        year: scan.year,
                        company: scan.company,
                        similarity: visualSimilarity,
                        frontUrl: scan.frontUrl
                    )
                    
                    if visualSimilarity > 0.70 {
                        print("✅ Match: \(scan.playerName) #\(scan.cardNumber) - Similarity: \(String(format: "%.2f", visualSimilarity))")
                    }
                    
                    return match
                }
            }
            
            // Collecter les résultats
            for await match in group {
                if let match = match {
                    visualMatches.append(match)
                }
            }
        }
        
        // 5. Trier par similarité et retourner top N
        visualMatches.sort { $0.similarity > $1.similarity }
        let finalMatches = Array(visualMatches.prefix(limit))
        
        print("🎉 Found \(finalMatches.count) matches (tested \(finalScansToTest.count) scans)")
        return finalMatches
    }
    
    // MARK: - Helper: Extract prefix and number from card number
    
    /// Extrait le préfixe et le numéro d'une carte
    /// Exemples: "381" → ("", 381), "MVP-7" → ("MVP", 7), "PC-12" → ("PC", 12)
    private func extractPrefixAndNumber(from cardNumber: String) -> (prefix: String, number: Int?) {
        let trimmed = cardNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Chercher un pattern "PREFIX-NUMBER" ou "PREFIX NUMBER"
        if let dashRange = trimmed.range(of: "-") {
            let prefix = String(trimmed[..<dashRange.lowerBound]).uppercased()
            let afterDash = String(trimmed[dashRange.upperBound...])
            let digits = afterDash.filter { $0.isNumber }
            let number = digits.isEmpty ? nil : Int(digits)
            return (prefix, number)
        }
        
        // Pas de dash, essayer de séparer lettres et chiffres
        let letters = trimmed.prefix(while: { $0.isLetter }).uppercased()
        let digits = trimmed.filter { $0.isNumber }
        
        if !letters.isEmpty && !digits.isEmpty {
            // Ex: "MVP7" → ("MVP", 7)
            return (String(letters), Int(digits))
        } else if !digits.isEmpty {
            // Ex: "381" → ("", 381)
            return ("", Int(digits))
        }
        
        // Pas de chiffres trouvés
        return ("", nil)
    }
    
    // MARK: - Private Helpers
    
    private func fetchAllScans() async throws -> [FirebaseScan] {
        let snapshot = try await db.collection("scans").getDocuments()
        
        var scans: [FirebaseScan] = []
        for document in snapshot.documents {
            if let scan = FirebaseScan(document: document) {
                scans.append(scan)
            }
        }
        
        return scans
    }
    
    
    private func downloadImageAsync(from urlString: String) async -> UIImage? {
        // Vérifier le cache
        if let cached = imageCache[urlString] {
            return cached
        }
        
        // Télécharger de façon asynchrone
        guard let url = URL(string: urlString) else {
            return nil
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else {
                return nil
            }
            
            // Mettre en cache (limiter à 50 images)
            await MainActor.run {
                if imageCache.count > 50 {
                    // Garder seulement les 25 plus récents
                    let keysToRemove = Array(imageCache.keys.prefix(imageCache.count - 25))
                    keysToRemove.forEach { imageCache.removeValue(forKey: $0) }
                }
                imageCache[urlString] = image
            }
            
            return image
        } catch {
            print("⚠️ Failed to download image: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func downloadImageSync(from urlString: String) -> UIImage? {
        // Vérifier le cache
        if let cached = imageCache[urlString] {
            return cached
        }
        
        // Télécharger
        guard let url = URL(string: urlString),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return nil
        }
        
        // Mettre en cache (limiter à 20 images pour éviter trop de mémoire)
        if imageCache.count > 20 {
            imageCache.removeAll()
        }
        imageCache[urlString] = image
        
        return image
    }
    
    nonisolated private func extractFeatures(from image: UIImage) -> VNFeaturePrintObservation? {
        guard let cgImage = image.cgImage else { return nil }
        
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            print("❌ Feature extraction failed: \(error)")
            return nil
        }
    }
    
    nonisolated private func compareFeatures(_ features1: VNFeaturePrintObservation, _ features2: VNFeaturePrintObservation) -> Double {
        var distance: Float = 0
        do {
            try features1.computeDistance(&distance, to: features2)
            // Distance est entre 0 (identique) et ~2 (très différent)
            // Convertir en similarité entre 0 et 1
            let similarity = max(0, 1.0 - Double(distance) / 2.0)
            return similarity
        } catch {
            print("❌ Distance calculation failed: \(error)")
            return 0
        }
    }
    
    private func calculateMetadataScore(scan: FirebaseScan, scannedFeatures: VNFeaturePrintObservation) -> Double {
        // Score basique basé sur les metadata disponibles
        // Utilisé pour filtrer rapidement avant le matching visuel
        
        let score: Double = 0.5 // Score de base
        
        // Pas de matching sur metadata pour l'instant (juste retourner score neutre)
        // Plus tard on pourrait ajouter des filtres par année, set, etc.
        
        return score
    }
}

// MARK: - Models

struct CardMatch {
    let scanId: String
    let playerName: String
    let cardNumber: String
    let setName: String
    let year: String
    let company: String
    let similarity: Double
    let frontUrl: String
}

struct FirebaseScan {
    let scanId: String
    let playerName: String
    let cardNumber: String
    let setName: String
    let year: String
    let company: String
    let frontUrl: String
    let backUrl: String
    
    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        
        guard let scanId = data["scanId"] as? String,
              let playerName = data["playerName"] as? String,
              let cardNumber = data["cardNumber"] as? String,
              let setName = data["setName"] as? String,
              let year = data["year"] as? String,
              let company = data["company"] as? String,
              let frontUrl = data["frontUrl"] as? String,
              let backUrl = data["backUrl"] as? String else {
            return nil
        }
        
        self.scanId = scanId
        self.playerName = playerName
        self.cardNumber = cardNumber
        self.setName = setName
        self.year = year
        self.company = company
        self.frontUrl = frontUrl
        self.backUrl = backUrl
    }
}

enum MatchError: Error {
    case featureExtractionFailed
    case noScansFound
    case downloadFailed
}
