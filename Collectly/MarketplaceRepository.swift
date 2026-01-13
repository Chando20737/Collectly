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

            // ✅ Auto-terminer les enchères expirées (si jamais une “active” est expirée)
            self.autoEndExpiredAuctionsIfNeeded(items)

            onUpdate(items)
        }
    }

    // ✅ Listener Mes annonces (sellerId == uid)
    func listenMyListings(
        limit: Int = 100,
        onUpdate: @escaping ([ListingCloud]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration? {

        guard let uid = Auth.auth().currentUser?.uid else {
            onUpdate([])
            return nil
        }

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

            // ✅ Auto-terminer les enchères expirées pour que “Mes annonces” devienne Terminée
            self.autoEndExpiredAuctionsIfNeeded(items)

            onUpdate(items)
        }
    }

    // MARK: - Auto end auctions

    /// Termine automatiquement (status="ended") les encans expirés.
    /// - important: Transaction pour éviter les doubles écritures / race conditions.
    private func autoEndExpiredAuctionsIfNeeded(_ items: [ListingCloud]) {
        let now = Date()

        let expired = items.filter { l in
            // Un encan = type "auction"
            guard l.type == "auction" else { return false }
            guard l.status == "active" else { return false }
            guard let end = l.endDate else { return false }
            return end <= now
        }

        guard !expired.isEmpty else { return }

        for l in expired {
            endAuctionIfExpiredTransaction(listingId: l.id)
        }
    }

    private func endAuctionIfExpiredTransaction(listingId: String) {
        let ref = db.collection("listings").document(listingId)
        let now = Date()

        db.runTransaction({ transaction, errorPointer in
            do {
                let snap = try transaction.getDocument(ref)
                guard snap.exists, let data = snap.data() else { return nil }

                let type = (data["type"] as? String) ?? ""
                let status = (data["status"] as? String) ?? ""
                guard type == "auction" else { return nil }
                guard status == "active" else { return nil }

                if let endTs = data["endDate"] as? Timestamp {
                    let endDate = endTs.dateValue()
                    guard endDate <= now else { return nil }

                    transaction.updateData([
                        "status": "ended",
                        "endedAt": Timestamp(date: now),
                        "updatedAt": Timestamp(date: now)
                    ], forDocument: ref)
                }

                return true
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }, completion: { _, error in
            if let error {
                // On ne bloque pas l'UI : best-effort
                print("⚠️ autoEndExpiredAuctions error:", error.localizedDescription)
            }
        })
    }
}

