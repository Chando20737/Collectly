//
//  ListingCloud.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation
import FirebaseFirestore
import SwiftUI

struct ListingCloud: Identifiable, Hashable {

    // MARK: - Core
    let id: String
    let sellerId: String
    let sellerUsername: String?
    let cardItemId: String

    let title: String
    let descriptionText: String?

    // "fixedPrice" | "auction"
    let type: String

    // "active" | "paused" | "sold" | "ended"
    let status: String

    // MARK: - Pricing
    let buyNowPriceCAD: Double?
    let startingBidCAD: Double?
    let currentBidCAD: Double?

    // MARK: - Auction
    let bidCount: Int
    let endDate: Date?
    let lastBidderId: String?
    let lastBidderUsername: String?

    // MARK: - Media
    let imageUrl: String?

    // MARK: - Dates
    let createdAt: Date
    let updatedAt: Date?

    // MARK: - Grading
    let isGraded: Bool?
    let gradingCompany: String?
    let gradeValue: String?
    let certificationNumber: String?

    // MARK: - Hashable (id suffit)
    static func == (lhs: ListingCloud, rhs: ListingCloud) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - UI helpers

    var shouldShowGradingBadge: Bool {
        let company = (gradingCompany ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let grade = (gradeValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !(company.isEmpty && grade.isEmpty)
    }

    var gradingLabel: String? {
        let company = (gradingCompany ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let grade = (gradeValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if company.isEmpty && grade.isEmpty { return nil }
        if company.isEmpty { return grade }
        if grade.isEmpty { return company }
        return "\(company) \(grade)"
    }

    /// Ce que tes vues utilisent : ListingBadgeView(text:, systemImage:, color:)
    var typeBadge: (text: String, icon: String, color: Color) {
        if type == "auction" {
            return ("Encan", "hammer.fill", .orange)
        }
        return ("Acheter maintenant", "tag.fill", .blue)
    }

    /// Badge de statut optionnel (ex: paused, sold, ended)
    var statusBadge: (text: String, icon: String, color: Color)? {
        switch status {
        case "paused":
            return ("En pause", "pause.circle.fill", .gray)
        case "sold":
            return ("Vendue", "checkmark.seal.fill", .purple)
        case "ended":
            return ("Terminée", "xmark.circle.fill", .red)
        default:
            // active -> pas besoin de badge de statut supplémentaire (souvent déjà implicite)
            return nil
        }
    }

    // MARK: - Firestore parsing

    static func fromFirestore(doc: DocumentSnapshot) -> ListingCloud {
        let data = doc.data() ?? [:]

        func str(_ key: String) -> String {
            (data[key] as? String) ?? ""
        }

        func optStr(_ key: String) -> String? {
            let v = (data[key] as? String) ?? ""
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        func optDouble(_ key: String) -> Double? {
            if let d = data[key] as? Double { return d }
            if let n = data[key] as? NSNumber { return n.doubleValue }
            return nil
        }

        func optInt(_ key: String) -> Int? {
            if let i = data[key] as? Int { return i }
            if let n = data[key] as? NSNumber { return n.intValue }
            return nil
        }

        func optDate(_ key: String) -> Date? {
            if let ts = data[key] as? Timestamp { return ts.dateValue() }
            return nil
        }

        let created = optDate("createdAt") ?? Date()
        let updated = optDate("updatedAt")

        return ListingCloud(
            id: doc.documentID,
            sellerId: str("sellerId"),
            sellerUsername: optStr("sellerUsername"),
            cardItemId: str("cardItemId"),

            title: str("title"),
            descriptionText: optStr("descriptionText"),

            type: str("type"),
            status: str("status"),

            buyNowPriceCAD: optDouble("buyNowPriceCAD"),
            startingBidCAD: optDouble("startingBidCAD"),
            currentBidCAD: optDouble("currentBidCAD"),

            bidCount: optInt("bidCount") ?? 0,
            endDate: optDate("endDate"),
            lastBidderId: optStr("lastBidderId"),
            lastBidderUsername: optStr("lastBidderUsername"),

            imageUrl: optStr("imageUrl"),

            createdAt: created,
            updatedAt: updated,

            isGraded: (data["isGraded"] as? Bool),
            gradingCompany: optStr("gradingCompany"),
            gradeValue: optStr("gradeValue"),
            certificationNumber: optStr("certificationNumber")
        )
    }
}
