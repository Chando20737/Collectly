//
//  Models.swift
//  Collectly
//
//  Modèles Firestore (Cloud)
//  - CardCloud : carte stockée dans Firestore
//  - ListingCloud : annonce Marketplace stockée dans Firestore
//
import Foundation
import FirebaseFirestore

// MARK: - CardCloud (Firestore)

struct CardCloud: Identifiable, Equatable {
    let id: String

    var ownerId: String
    var title: String
    var notes: String?
    var imageUrl: String?

    var createdAt: Date
    var updatedAt: Date

    static func fromFirestore(doc: DocumentSnapshot) -> CardCloud {
        let data = doc.data() ?? [:]

        func date(_ key: String) -> Date {
            (data[key] as? Timestamp)?.dateValue() ?? Date()
        }

        return CardCloud(
            id: doc.documentID,
            ownerId: data["ownerId"] as? String ?? "",
            title: data["title"] as? String ?? "",
            notes: data["notes"] as? String,
            imageUrl: data["imageUrl"] as? String,
            createdAt: date("createdAt"),
            updatedAt: date("updatedAt")
        )
    }

    func toFirestore() -> [String: Any] {
        var dict: [String: Any] = [
            "ownerId": ownerId,
            "title": title,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt)
        ]
        if let notes { dict["notes"] = notes }
        if let imageUrl { dict["imageUrl"] = imageUrl }
        return dict
    }
}

