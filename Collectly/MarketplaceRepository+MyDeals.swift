//
//  MarketplaceRepository+MyDeals.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-14.
//
import Foundation
import FirebaseFirestore

extension MarketplaceRepository {

    /// ✅ Mes ventes = sellerId == userId
    func listenMySales(
        sellerId: String,
        limit: Int = 200,
        onUpdate: @escaping ([ListingCloud]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration {

        let db = Firestore.firestore()

        // ⚠️ Peut demander un index composite selon tes autres where/orderBy
        let q = db.collection("listings")
            .whereField("sellerId", isEqualTo: sellerId)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)

        return q.addSnapshotListener { snap, err in
            if let err { onError(err); return }
            guard let snap else { onUpdate([]); return }
            let items = snap.documents.map { ListingCloud.fromFirestore(doc: $0) }
            onUpdate(items)
        }
    }

    /// ✅ Mes enchères (MVP) = lastBidderId == userId
    /// Remarque: ça montre les enchères où TU es actuellement le dernier.
    func listenMyBidListings(
        bidderId: String,
        limit: Int = 200,
        onUpdate: @escaping ([ListingCloud]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration {

        let db = Firestore.firestore()

        // On filtre type == auction pour éviter le bruit
        // ⚠️ peut demander un index composite (lastBidderId + type + createdAt)
        let q = db.collection("listings")
            .whereField("type", isEqualTo: "auction")
            .whereField("lastBidderId", isEqualTo: bidderId)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)

        return q.addSnapshotListener { snap, err in
            if let err { onError(err); return }
            guard let snap else { onUpdate([]); return }
            let items = snap.documents.map { ListingCloud.fromFirestore(doc: $0) }
            onUpdate(items)
        }
    }
}

