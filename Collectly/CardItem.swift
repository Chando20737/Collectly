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

    // ✅ Grading
    var isGraded: Bool?
    var gradingCompany: String?
    var gradeValue: String?
    var certificationNumber: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        ownerId: String,
        title: String,
        notes: String? = nil,
        frontImageData: Data? = nil,
        estimatedPriceCAD: Double? = nil,
        playerName: String? = nil,
        cardYear: String? = nil,
        companyName: String? = nil,
        setName: String? = nil,
        cardNumber: String? = nil,
        isGraded: Bool? = nil,
        gradingCompany: String? = nil,
        gradeValue: String? = nil,
        certificationNumber: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.ownerId = ownerId
        self.title = title
        self.notes = notes
        self.frontImageData = frontImageData
        self.estimatedPriceCAD = estimatedPriceCAD
        self.playerName = playerName
        self.cardYear = cardYear
        self.companyName = companyName
        self.setName = setName
        self.cardNumber = cardNumber
        self.isGraded = isGraded
        self.gradingCompany = gradingCompany
        self.gradeValue = gradeValue
        self.certificationNumber = certificationNumber
    }
}

