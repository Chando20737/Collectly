//
//  ListingCloud.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation
import FirebaseFirestore
import SwiftUI

struct ListingCloud: Identifiable, Equatable {

    // MARK: - Identité
    let id: String

    // MARK: - Propriétaire
    var sellerId: String
    var sellerUsername: String?

    // MARK: - Référence à ta carte locale
    var cardItemId: String

    // MARK: - Infos annonce
    var title: String
    var descriptionText: String?

    /// "fixedPrice" | "auction"
    var type: String

    /// "active" | "paused" | "sold" | "ended"
    var status: String

    // MARK: - Médias
    var imageUrl: String?

    // MARK: - Prix / Encan
    var buyNowPriceCAD: Double?
    var startingBidCAD: Double?
    var endDate: Date?
    var currentBidCAD: Double?
    var bidCount: Int

    // ✅ Champs rapides de bids
    var lastBidderId: String?
    var lastBidderUsername: String?
    var lastBidAt: Date?

    // ✅ Résultat final (quand encan terminé)
    var endedAt: Date?
    var winnerId: String?
    var winnerUsername: String?
    var winningBidCAD: Double?

    // MARK: - ✅ Grading
    var isGraded: Bool?
    var gradingCompany: String?
    var gradeValue: String?
    var certificationNumber: String?

    // MARK: - Dates
    var createdAt: Date
    var updatedAt: Date?

    // MARK: - Mapping

    static func fromFirestore(doc: DocumentSnapshot) -> ListingCloud {
        let data = doc.data() ?? [:]
        return fromData(docId: doc.documentID, data: data)
    }

    static func fromData(docId: String, data: [String: Any]) -> ListingCloud {
        func date(_ key: String) -> Date? {
            (data[key] as? Timestamp)?.dateValue()
        }

        return ListingCloud(
            id: docId,

            sellerId: data["sellerId"] as? String ?? "",
            sellerUsername: data["sellerUsername"] as? String,

            cardItemId: data["cardItemId"] as? String ?? "",

            title: data["title"] as? String ?? "Annonce",
            descriptionText: data["descriptionText"] as? String,

            type: data["type"] as? String ?? "fixedPrice",
            status: data["status"] as? String ?? "active",

            imageUrl: data["imageUrl"] as? String,

            buyNowPriceCAD: data["buyNowPriceCAD"] as? Double,

            startingBidCAD: data["startingBidCAD"] as? Double,
            endDate: date("endDate"),
            currentBidCAD: data["currentBidCAD"] as? Double,
            bidCount: data["bidCount"] as? Int ?? 0,

            lastBidderId: data["lastBidderId"] as? String,
            lastBidderUsername: data["lastBidderUsername"] as? String,
            lastBidAt: date("lastBidAt"),

            endedAt: date("endedAt"),
            winnerId: data["winnerId"] as? String,
            winnerUsername: data["winnerUsername"] as? String,
            winningBidCAD: data["winningBidCAD"] as? Double,

            isGraded: data["isGraded"] as? Bool,
            gradingCompany: data["gradingCompany"] as? String,
            gradeValue: data["gradeValue"] as? String,
            certificationNumber: data["certificationNumber"] as? String,

            createdAt: date("createdAt") ?? Date(),
            updatedAt: date("updatedAt")
        )
    }

    func toFirestore() -> [String: Any] {
        var dict: [String: Any] = [
            "sellerId": sellerId,
            "cardItemId": cardItemId,
            "title": title,
            "type": type,
            "status": status,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt ?? Date()),
            "bidCount": bidCount
        ]

        if let sellerUsername, !sellerUsername.isEmpty { dict["sellerUsername"] = sellerUsername }
        if let descriptionText, !descriptionText.isEmpty { dict["descriptionText"] = descriptionText }
        if let imageUrl, !imageUrl.isEmpty { dict["imageUrl"] = imageUrl }

        if let buyNowPriceCAD { dict["buyNowPriceCAD"] = buyNowPriceCAD }
        if let startingBidCAD { dict["startingBidCAD"] = startingBidCAD }
        if let endDate { dict["endDate"] = Timestamp(date: endDate) }
        if let currentBidCAD { dict["currentBidCAD"] = currentBidCAD }

        if let lastBidderId { dict["lastBidderId"] = lastBidderId }
        if let lastBidderUsername { dict["lastBidderUsername"] = lastBidderUsername }
        if let lastBidAt { dict["lastBidAt"] = Timestamp(date: lastBidAt) }

        if let endedAt { dict["endedAt"] = Timestamp(date: endedAt) }
        if let winnerId { dict["winnerId"] = winnerId }
        if let winnerUsername { dict["winnerUsername"] = winnerUsername }
        if let winningBidCAD { dict["winningBidCAD"] = winningBidCAD }

        if let isGraded { dict["isGraded"] = isGraded }
        if let gradingCompany, !gradingCompany.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["gradingCompany"] = gradingCompany
        }
        if let gradeValue, !gradeValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["gradeValue"] = gradeValue
        }
        if let certificationNumber, !certificationNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["certificationNumber"] = certificationNumber
        }

        return dict
    }
}

// MARK: - UX Badges

extension ListingCloud {

    var typeBadge: (text: String, icon: String, color: Color) {
        if type == "fixedPrice" {
            return ("Prix fixe", "tag.fill", .blue)
        } else {
            return ("Encan", "hammer.fill", .orange)
        }
    }

    var statusBadge: (text: String, icon: String, color: Color)? {
        switch status {
        case "active":
            return ("Active", "checkmark.circle.fill", .green)
        case "paused":
            return ("En pause", "pause.circle.fill", .orange)
        case "sold":
            return ("Vendue", "checkmark.seal.fill", .blue)
        case "ended":
            return ("Terminée", "flag.checkered", .gray)
        default:
            return nil
        }
    }

    var gradingLabel: String? {
        let g = gradeValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if g.isEmpty { return nil }
        let c = gradingCompany?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return c.isEmpty ? g : "\(c) \(g)"
    }

    var shouldShowGradingBadge: Bool {
        return gradingLabel != nil
    }
}
