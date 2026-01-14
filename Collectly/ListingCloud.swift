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

    /// "fixedPrice" | "auction"
    let type: String

    /// "active" | "paused" | "sold" | "ended"
    let status: String

    // MARK: - Pricing
    let buyNowPriceCAD: Double?          // fixedPrice
    let startingBidCAD: Double?          // auction
    let currentBidCAD: Double?           // auction
    let bidCount: Int                   // auction

    // MARK: - Auction
    let endDate: Date?

    // MARK: - Media
    let imageUrl: String?

    // MARK: - Dates
    let createdAt: Date
    let updatedAt: Date?

    // MARK: - Bids meta
    let lastBidderId: String?
    let lastBidderUsername: String?

    // MARK: - Grading
    let isGraded: Bool
    let gradingCompany: String?
    let gradeValue: String?
    let certificationNumber: String?

    // MARK: - UI helpers

    struct Badge: Hashable {
        let text: String
        let icon: String
        let color: Color
    }

    var typeBadge: Badge {
        if type == "auction" {
            return Badge(text: "Encan", icon: "hammer.fill", color: .orange)
        } else {
            return Badge(text: "Acheter maintenant", icon: "tag.fill", color: .blue)
        }
    }

    var statusBadge: Badge? {
        switch status {
        case "active":
            return Badge(text: "Active", icon: "checkmark.circle.fill", color: .green)
        case "paused":
            return Badge(text: "En pause", icon: "pause.circle.fill", color: .gray)
        case "sold":
            return Badge(text: "Vendue", icon: "checkmark.seal.fill", color: .purple)
        case "ended":
            return Badge(text: "Terminée", icon: "xmark.circle.fill", color: .red)
        default:
            return nil
        }
    }

    var gradingLabel: String? {
        let comp = (gradingCompany ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let grade = (gradeValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !comp.isEmpty && !grade.isEmpty {
            return "\(comp) \(grade)"
        }
        if !grade.isEmpty { return grade }
        return nil
    }

    var shouldShowGradingBadge: Bool {
        isGraded && (gradingLabel?.isEmpty == false)
    }

    // MARK: - Firestore parsing

    static func fromFirestore(doc: DocumentSnapshot) -> ListingCloud {
        let data = doc.data() ?? [:]

        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(timeIntervalSince1970: 0)
        let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue()

        let endDate = (data["endDate"] as? Timestamp)?.dateValue()

        // ✅ Robust number casts
        let bidCount = readInt(data["bidCount"]) ?? 0
        let buyNow = readDouble(data["buyNowPriceCAD"])
        let starting = readDouble(data["startingBidCAD"])
        let current = readDouble(data["currentBidCAD"])

        let isGraded = (data["isGraded"] as? Bool) ?? false

        return ListingCloud(
            id: doc.documentID,
            sellerId: (data["sellerId"] as? String) ?? "",
            sellerUsername: data["sellerUsername"] as? String,
            cardItemId: (data["cardItemId"] as? String) ?? "",

            title: (data["title"] as? String) ?? "",
            descriptionText: data["descriptionText"] as? String,

            type: (data["type"] as? String) ?? "fixedPrice",
            status: (data["status"] as? String) ?? "active",

            buyNowPriceCAD: buyNow,
            startingBidCAD: starting,
            currentBidCAD: current,
            bidCount: bidCount,

            endDate: endDate,

            imageUrl: data["imageUrl"] as? String,

            createdAt: createdAt,
            updatedAt: updatedAt,

            lastBidderId: data["lastBidderId"] as? String,
            lastBidderUsername: data["lastBidderUsername"] as? String,

            isGraded: isGraded,
            gradingCompany: data["gradingCompany"] as? String,
            gradeValue: data["gradeValue"] as? String,
            certificationNumber: data["certificationNumber"] as? String
        )
    }

    private static func readInt(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let i64 = any as? Int64 { return Int(i64) }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    private static func readDouble(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let i64 = any as? Int64 { return Double(i64) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
