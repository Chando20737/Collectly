//
//  CardItem.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation
import SwiftData

@Model
final class CardItem {
    var id: UUID
    var createdAt: Date

    // ✅ IMPORTANT: associer la carte à un user Firebase
    var ownerId: String

    // Affichage rapide / v0.1
    var title: String
    var notes: String?

    // ✅ Favori (local)
    var isFavorite: Bool

    // Stocke l’image en Data (simple pour V0.1)
    var frontImageData: Data?

    // ✅ Dos de la carte (pour OCR + historique)
    var backImageData: Data?

    // Prix (on remplira via eBay plus tard)
    var estimatedPriceCAD: Double?

    // ✅ Pricing metadata (source + confiance + date)
    // NOTE: on stocke des Strings/Double/Date pour rester simple avec SwiftData.
    // priceSourceRaw: "local" | "ebay" | "heuristic" | "manual"
    var priceSourceRaw: String?
    var priceConfidence: Double?
    var lastPriceUpdate: Date?

    // ✅ Fiche de la carte
    var playerName: String?
    var cardYear: String?            // ex: "2023-24"
    var companyName: String?         // ex: "Upper Deck", "Topps", "Panini"
    var setName: String?             // ex: "Series 1", "SP Authentic"
    var cardNumber: String?          // ex: "#201"

    // ✅ Firebase sync
    var firebaseId: String?          // ID du document Firebase pour éviter les doublons


// ✅ Badges (Auto + Manuel)
// badgeModeRaw: "auto" | "mix" | "manual" (default: "mix")
var badgeModeRaw: String?
// manualBadgesRaw: "rookie,autograph" etc.
var manualBadgesRaw: String?
// disabledBadgesRaw: badges to hide even if auto detects them (e.g., "patch")
var disabledBadgesRaw: String?

// ✅ eBay price range (CAD) + sample size
var priceMinCAD: Double?
var priceMedianCAD: Double?
var priceMaxCAD: Double?
var priceSampleCount: Int?

    // ✅ Grading
    var isGraded: Bool = false
    var gradingCompany: String?
    var gradeValue: String?
    var certificationNumber: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        ownerId: String,
        title: String,
        notes: String? = nil,
        isFavorite: Bool = false,
        frontImageData: Data? = nil,
        backImageData: Data? = nil,
        estimatedPriceCAD: Double? = nil,
        priceSourceRaw: String? = nil,
        priceConfidence: Double? = nil,
        lastPriceUpdate: Date? = nil,
        playerName: String? = nil,
        cardYear: String? = nil,
        companyName: String? = nil,
        setName: String? = nil,
        cardNumber: String? = nil,
        badgeModeRaw: String? = "mix",
        manualBadgesRaw: String? = nil,
        disabledBadgesRaw: String? = nil,
        priceMinCAD: Double? = nil,
        priceMedianCAD: Double? = nil,
        priceMaxCAD: Double? = nil,
        priceSampleCount: Int? = nil,
        isGraded: Bool = false,
        gradingCompany: String? = nil,
        gradeValue: String? = nil,
        certificationNumber: String? = nil,
        firebaseId: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.ownerId = ownerId
        self.title = title
        self.notes = notes
        self.isFavorite = isFavorite
        self.frontImageData = frontImageData
        self.backImageData = backImageData
        self.estimatedPriceCAD = estimatedPriceCAD
        self.priceSourceRaw = priceSourceRaw
        self.priceConfidence = priceConfidence
        self.lastPriceUpdate = lastPriceUpdate
        self.playerName = playerName
        self.cardYear = cardYear
        self.companyName = companyName
        self.setName = setName
        self.cardNumber = cardNumber
        self.badgeModeRaw = badgeModeRaw
        self.manualBadgesRaw = manualBadgesRaw
        self.disabledBadgesRaw = disabledBadgesRaw
        self.priceMinCAD = priceMinCAD
        self.priceMedianCAD = priceMedianCAD
        self.priceMaxCAD = priceMaxCAD
        self.priceSampleCount = priceSampleCount
        self.isGraded = isGraded
        self.gradingCompany = gradingCompany
        self.gradeValue = gradeValue
        self.certificationNumber = certificationNumber
        self.firebaseId = firebaseId
    }
}

// MARK: - Grading Extensions

extension CardItem {
    
    /// Description lisible du grading (ex: "PSA 10", "BGS 9.5")
    var gradingDescription: String? {
        guard isGraded else { return nil }
        
        var parts: [String] = []
        
        if let company = gradingCompany {
            parts.append(company)
        }
        
        if let grade = gradeValue {
            parts.append(grade)
        }
        
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
    
    /// Vérifie si la carte a toutes les infos de grading nécessaires
    var hasCompleteGradingInfo: Bool {
        guard isGraded else { return false }
        return gradingCompany != nil && gradeValue != nil
    }
    
    /// Grade numérique extrait (ex: "GEM MT 10" -> "10", "9.5" -> "9.5")
    var numericGrade: String? {
        guard let gradeValue = gradeValue else { return nil }
        
        let cleaned = gradeValue
            .replacingOccurrences(of: "GEM MT", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "MINT", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned.isEmpty ? nil : cleaned
    }
    
    /// Icône SF Symbol appropriée pour la compagnie de grading
    var gradingIcon: String {
        guard isGraded else { return "questionmark.square.dashed" }
        
        switch gradingCompany?.uppercased() {
        case "PSA":
            return "checkmark.seal.fill"  // Bleu
        case "BGS", "BECKETT":
            return "rosette"              // Orange
        case "SGC":
            return "shield.fill"          // Vert
        case "CGC":
            return "crown.fill"           // Jaune
        default:
            return "checkmark.circle.fill"
        }
    }
}

