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

    // Affichage rapide / v0.1
    var title: String
    var notes: String?

    // Stocke l’image en Data (simple pour V0.1)
    var frontImageData: Data?

    // Prix (on remplira via eBay plus tard)
    var estimatedPriceCAD: Double?

    // ✅ Fiche de la carte
    var playerName: String?
    var cardYear: String?            // ex: "2023-24"
    var companyName: String?         // ex: "Upper Deck", "Topps", "Panini"
    var setName: String?             // ex: "Series 1", "SP Authentic"
    var cardNumber: String?          // ex: "#201"

    // ✅ Grading (IMPORTANT: optionnel pour migration)
    var isGraded: Bool?              // nil = inconnu / non rempli, traité comme "Non" en UI
    var gradingCompany: String?      // ex: "PSA", "BGS", "SGC", "CGC"
    var gradeValue: String?          // ex: "10", "9.5"
    var certificationNumber: String? // ex: "12345678"

    // ✅ Acquisition
    var acquisitionDate: Date?
    var acquisitionSource: String?   // ex: "eBay", "Boutique", "Échange"
    var purchasePriceCAD: Double?    // prix payé (CAD)

    init(title: String, notes: String? = nil, frontImageData: Data? = nil) {
        self.id = UUID()
        self.createdAt = Date()
        self.title = title
        self.notes = notes
        self.frontImageData = frontImageData
        self.estimatedPriceCAD = nil

        self.playerName = nil
        self.cardYear = nil
        self.companyName = nil
        self.setName = nil
        self.cardNumber = nil

        self.isGraded = nil
        self.gradingCompany = nil
        self.gradeValue = nil
        self.certificationNumber = nil

        self.acquisitionDate = nil
        self.acquisitionSource = nil
        self.purchasePriceCAD = nil
    }
}
