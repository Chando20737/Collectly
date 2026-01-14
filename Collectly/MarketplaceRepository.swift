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

    private let db = Firestore.firestore()

    // MARK: - PUBLIC MARKETPLACE (ACTIVE ONLY)
    //
    // ✅ IMPORTANT:
    // - Ici, on ne montre QUE "active"
    // -> "paused" disparait automatiquement du Marketplace
    //
    // ✅ Sans orderBy -> pas d’index composite requis
    // On trie côté iPhone (createdAt desc)

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
                    onError(error)
                    onUpdate([])
                    return
                }

                guard let snap else {
                    onUpdate([])
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
                onUpdate(items)
            }

        return listener
    }

    // MARK: - MY LISTINGS (private)
    //
    // ✅ Ici on veut TOUT voir (active, paused, sold, ended)
    // ✅ Sans orderBy -> pas d’index composite requis
    // On trie localement

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
                    onError(error)
                    onUpdate([])
                    return
                }

                guard let snap else {
                    onUpdate([])
                    return
                }

                var items: [ListingCloud] = []
                items.reserveCapacity(snap.documents.count)

                for doc in snap.documents {
                    let l = ListingCloud.fromFirestore(doc: doc)
                    items.append(l)
                }

                items.sort { a, b in a.createdAt > b.createdAt }
                onUpdate(items)
            }

        return listener
    }

    // MARK: - CREATE FREE LISTING (Hybrid)
    //
    // ✅ Annonce libre (sans carte liée)
    // - Pas d’image uploadée pour l’instant -> imageUrl = nil
    // - cardId = nil
    // - On met "active" par défaut

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

        let now = Date()

        var data: [String: Any] = [
            "title": cleanTitle,
            "descriptionText": descriptionText as Any,
            "type": (type == .auction) ? "auction" : "fixedPrice",
            "status": "active",
            "createdAt": Timestamp(date: now),
            "sellerId": user.uid
        ]

        // Hybride: annonce libre
        data["cardId"] = NSNull()
        data["imageUrl"] = NSNull()

        if type == .fixedPrice {
            data["buyNowPriceCAD"] = buyNowPriceCAD as Any
            data["startingBidCAD"] = NSNull()
            data["currentBidCAD"] = NSNull()
            data["bidCount"] = 0
            data["endDate"] = NSNull()
        } else {
            data["buyNowPriceCAD"] = NSNull()
            data["startingBidCAD"] = startingBidCAD as Any
            data["currentBidCAD"] = NSNull()
            data["bidCount"] = 0
            data["endDate"] = endDate != nil ? Timestamp(date: endDate!) : NSNull()
        }

        try await db.collection("listings").addDocument(data: data)
    }

    // MARK: - STATUS / DELETE

    func setListingStatus(listingId: String, status: String) async throws {
        try await db.collection("listings").document(listingId).updateData([
            "status": status
        ])
    }

    func deleteListing(listingId: String) async throws {
        try await db.collection("listings").document(listingId).delete()
    }

    // MARK: - UPDATE LISTING (Edit)
    //
    // ✅ Édition safe (MVP):
    // - title, descriptionText
    // - buyNowPriceCAD (si fixedPrice)
    // - startingBidCAD (si auction ET bidCount == 0)
    // - endDate NON modifiable ici
    //
    // NOTE: on garde la compatibilité avec tes docs existants (aucun champ obligatoire ajouté).

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

        var data: [String: Any] = [
            "title": cleanTitle,
            "descriptionText": descriptionText as Any
        ]

        if typeString == "fixedPrice" {
            data["buyNowPriceCAD"] = buyNowPriceCAD as Any
            // on ne touche pas aux champs d'encan
        } else {
            // auction
            // On autorise la mise de départ seulement s'il n'y a aucune mise
            if bidCount == 0 {
                data["startingBidCAD"] = startingBidCAD as Any
            }
        }

        try await db.collection("listings").document(listingId).updateData(data)
    }
}
