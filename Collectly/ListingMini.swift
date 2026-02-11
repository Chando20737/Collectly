//
//  ListingMini.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-14.
//
import Foundation
import FirebaseFirestore

struct ListingMini: Identifiable {
    let id: String
    let type: String
    let status: String
    let buyNowPriceCAD: Double?
    let startingBidCAD: Double?
    let currentBidCAD: Double?
    let bidCount: Int
    let endDate: Date?

    var typeLabel: String { type == "fixedPrice" ? "Prix fixe" : "Encan" }

    var statusLabel: String {
        switch status {
        case "active": return "Active"
        case "paused": return "En pause"
        case "sold": return "Vendue"
        case "ended": return "Terminée"
        default: return status
        }
    }

    static func fromFirestore(doc: DocumentSnapshot) -> ListingMini {
        let data = doc.data() ?? [:]
        func date(_ key: String) -> Date? { (data[key] as? Timestamp)?.dateValue() }

        return ListingMini(
            id: doc.documentID,
            type: data["type"] as? String ?? "fixedPrice",
            status: data["status"] as? String ?? "active",
            buyNowPriceCAD: data["buyNowPriceCAD"] as? Double,
            startingBidCAD: data["startingBidCAD"] as? Double,
            currentBidCAD: data["currentBidCAD"] as? Double,
            bidCount: data["bidCount"] as? Int ?? 0,
            endDate: date("endDate")
        )
    }
}

