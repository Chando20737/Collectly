//
//  MarketplaceRepository.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation
import FirebaseAuth
import FirebaseFirestore

final class MarketplaceRepository {

    // ✅ IMPORTANT:
    // "private" empêche l’accès depuis une extension dans un autre fichier.
    // On le laisse "internal" (par défaut) pour MarketplaceRepository+MyDeals.swift.
    let db: Firestore = Firestore.firestore()

    // MARK: - PUBLIC MARKETPLACE (ACTIVE ONLY)

    func listenPublicActiveListings(
        limit: Int = 200,
        onUpdate: @escaping ([ListingCloud]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration {

        let listener = db.collection("listings")
            .whereField("status", isEqualTo: "active")
            .limit(to: limit)
            .addSnapshotListener { snap, error in

                if let error = error as NSError? {
                    DispatchQueue.main.async {
                        onError(error)
                        onUpdate([])
                    }
                    return
                }

                guard let snap else {
                    DispatchQueue.main.async { onUpdate([]) }
                    return
                }

                var items: [ListingCloud] = []
                items.reserveCapacity(snap.documents.count)

                for doc in snap.documents {
                    let l = ListingCloud.fromFirestore(doc: doc)
                    if l.status == "active" {
                        items.append(l)
                    }
                }

                items.sort { a, b in a.createdAt > b.createdAt }

                DispatchQueue.main.async {
                    onUpdate(items)
                }
            }

        return listener
    }

    // MARK: - MY LISTINGS (private)

    func listenMyListings(
        uid: String,
        limit: Int = 200,
        onUpdate: @escaping ([ListingCloud]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration {

        let listener = db.collection("listings")
            .whereField("sellerId", isEqualTo: uid)
            .limit(to: limit)
            .addSnapshotListener { snap, error in

                if let error = error as NSError? {
                    DispatchQueue.main.async {
                        onError(error)
                        onUpdate([])
                    }
                    return
                }

                guard let snap else {
                    DispatchQueue.main.async { onUpdate([]) }
                    return
                }

                var items: [ListingCloud] = []
                items.reserveCapacity(snap.documents.count)

                for doc in snap.documents {
                    items.append(ListingCloud.fromFirestore(doc: doc))
                }

                items.sort { a, b in a.createdAt > b.createdAt }

                DispatchQueue.main.async {
                    onUpdate(items)
                }
            }

        return listener
    }

    // MARK: - CREATE FREE LISTING (Hybrid)

    func createFreeListing(
        title: String,
        descriptionText: String?,
        type: ListingType,
        buyNowPriceCAD: Double?,
        startingBidCAD: Double?,
        endDate: Date?
    ) async throws {

        guard let user = Auth.auth().currentUser else {
            throw NSError(
                domain: "MarketplaceRepository",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Tu dois être connecté pour publier une annonce."]
            )
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty {
            throw NSError(
                domain: "MarketplaceRepository",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Le titre est obligatoire."]
            )
        }

        let cleanDesc = (descriptionText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let descOrNil: String? = cleanDesc.isEmpty ? nil : cleanDesc

        let freeCardItemId = UUID().uuidString

        var data: [String: Any] = [
            "title": cleanTitle,
            "type": (type == .auction) ? "auction" : "fixedPrice",
            "status": "active",
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp(),
            "sellerId": user.uid,
            "cardItemId": freeCardItemId,
            "bidCount": 0
        ]

        if let descOrNil {
            data["descriptionText"] = descOrNil
        }

        if type == .fixedPrice {
            guard let p = buyNowPriceCAD, p > 0 else {
                throw NSError(
                    domain: "MarketplaceRepository",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Entre un prix valide (ex: 25)."]
                )
            }
            data["buyNowPriceCAD"] = p

        } else {
            guard let endDate else {
                throw NSError(
                    domain: "MarketplaceRepository",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Un encan doit avoir une date de fin."]
                )
            }

            let now = Date()
            let minEnd = now.addingTimeInterval(8 * 60 * 60 + 120)
            if endDate <= minEnd {
                throw NSError(
                    domain: "MarketplaceRepository",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Un encan doit durer au minimum 8 heures."]
                )
            }

            let start = startingBidCAD ?? 0
            if start < 0 {
                throw NSError(
                    domain: "MarketplaceRepository",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "La mise de départ doit être 0 ou plus."]
                )
            }

            data["startingBidCAD"] = start
            data["currentBidCAD"] = start
            data["endDate"] = Timestamp(date: endDate)
        }

        try await db.collection("listings").addDocument(data: data)
    }

    // MARK: - STATUS

    func setListingStatus(listingId: String, status: String) async throws {
        try await db.collection("listings").document(listingId).updateData([
            "status": status,
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }

    // MARK: - DELETE

    func deleteListing(listingId: String) async throws {
        try await db.collection("listings").document(listingId).delete()
    }

    // MARK: - UPDATE LISTING (Edit)

    func updateListing(
        listingId: String,
        title: String,
        descriptionText: String?,
        typeString: String,
        buyNowPriceCAD: Double?,
        startingBidCAD: Double?,
        bidCount: Int
    ) async throws {

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty {
            throw NSError(
                domain: "MarketplaceRepository",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Le titre est obligatoire."]
            )
        }

        let cleanDesc = (descriptionText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let descOrNil: String? = cleanDesc.isEmpty ? nil : cleanDesc

        var data: [String: Any] = [
            "title": cleanTitle,
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if let descOrNil {
            data["descriptionText"] = descOrNil
        } else {
            data["descriptionText"] = FieldValue.delete()
        }

        if typeString == "fixedPrice" {
            if let p = buyNowPriceCAD, p > 0 {
                data["buyNowPriceCAD"] = p
            } else {
                data["buyNowPriceCAD"] = FieldValue.delete()
            }
        } else {
            if bidCount == 0 {
                if let s = startingBidCAD, s >= 0 {
                    data["startingBidCAD"] = s
                } else {
                    data["startingBidCAD"] = FieldValue.delete()
                }
            }
        }

        try await db.collection("listings").document(listingId).updateData(data)
    }
}
