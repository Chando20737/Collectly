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
            .whereField("status", isEqualTo: "active") // ✅ KEY: ONLY active is public
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

                    // ✅ Double sécurité si jamais un doc "paused" passe par erreur
                    if l.status == "active" {
                        items.append(l)
                    }
                }

                // Tri local (plus récent en premier)
                items.sort { a, b in
                    a.createdAt > b.createdAt
                }

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

                // Tri local (plus récent en premier)
                items.sort { a, b in
                    a.createdAt > b.createdAt
                }

                onUpdate(items)
            }

        return listener
    }
}
