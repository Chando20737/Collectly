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

        return q.addSnapshotListener { [weak self] snap, error in
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

            // ✅ Auto-terminer les enchères expirées (best effort)
            self?.autoEndExpiredAuctionsIfNeeded(items)

            onUpdate(items)
        }
    }

    // ✅ Listener Mes annonces (sellerId == uid) — on passe uid depuis la View
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

        return q.addSnapshotListener { [weak self] snap, error in
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
            self?.autoEndExpiredAuctionsIfNeeded(items)

            onUpdate(items)
        }
    }

    // MARK: - Auto end auctions

    /// Termine automatiquement (status="ended") les encans expirés.
    /// - Best effort : on ne bloque pas l'UI si ça échoue.
    private func autoEndExpiredAuctionsIfNeeded(_ items: [ListingCloud]) {
        let now = Date()

        let expiredIds = items.compactMap { l -> String? in
            guard l.type == "auction" else { return nil }
            guard l.status == "active" else { return nil }
            guard let end = l.endDate else { return nil }
            return (end <= now) ? l.id : nil
        }

        guard !expiredIds.isEmpty else { return }

        for id in expiredIds {
            endAuctionIfExpiredTransaction(listingId: id)
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

                guard let endTs = data["endDate"] as? Timestamp else { return nil }
                let endDate = endTs.dateValue()
                guard endDate <= now else { return nil }

                transaction.updateData([
                    "status": "ended",
                    "endedAt": Timestamp(date: now),
                    "updatedAt": Timestamp(date: now)
                ], forDocument: ref)

                return true
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }, completion: { _, error in
            if let error {
                // Best effort : on ne bloque pas l'UI
                print("⚠️ autoEndExpiredAuctions error:", error.localizedDescription)
            }
        })
    }
}
