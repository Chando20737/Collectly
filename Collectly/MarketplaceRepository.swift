//
//  MarketplaceRepository.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation
import FirebaseFirestore

final class MarketplaceRepository {

    private let db = Firestore.firestore()

    // ✅ Listener Marketplace public (seulement les annonces actives)
    func listenPublicActiveListings(
        limit: Int = 50,
        onUpdate: @escaping ([ListingCloud]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration {

        let q = db.collection("listings")
            .whereField("status", isEqualTo: "active")
            .order(by: "createdAt", descending: true)
            .limit(to: limit)

        return q.addSnapshotListener { snap, error in
            if let error {
                print("🔥 LISTENER ERROR in MarketplaceRepository.listenPublicActiveListings:", error)
                onError(error)
                return
            }

            guard let snap else {
                onUpdate([])
                return
            }

            let items = snap.documents.map { ListingCloud.fromFirestore(doc: $0) }
            onUpdate(items)
        }
    }

    // ✅ Listener Mes annonces (sellerId == uid) — uid passé depuis la View
    func listenMyListings(
        uid: String,
        limit: Int = 100,
        onUpdate: @escaping ([ListingCloud]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration {

        let q = db.collection("listings")
            .whereField("sellerId", isEqualTo: uid)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)

        return q.addSnapshotListener { snap, error in
            if let error {
                print("🔥 LISTENER ERROR in MarketplaceRepository.listenMyListings:", error)
                onError(error)
                return
            }

            guard let snap else {
                onUpdate([])
                return
            }

            let items = snap.documents.map { ListingCloud.fromFirestore(doc: $0) }
            onUpdate(items)
        }
    }
}
