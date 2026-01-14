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
    // - On ne montre QUE "active"
    // - Pas de orderBy -> pas d’index composite requis
    // - On trie côté iPhone (createdAt desc)
    // ✅ FIX: callbacks sur Main Thread

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
                    let l = ListingCloud.fromFirestore(doc: doc)
                    items.append(l)
                }

                items.sort { a, b in a.createdAt > b.createdAt }

                DispatchQueue.main.async {
                    onUpdate(items)
                }
            }

        return listener
    }

    // MARK: - CREATE FREE LISTING (Hybrid)
    //
    // ✅ IMPORTANT pour tes rules:
    // - fixedPrice: buyNowPriceCAD DOIT être number > 0
    // - auction:
    //   - startingBidCAD doit être number >= 0
    //   - currentBidCAD doit être number >= startingBidCAD (donc on le met = startingBidCAD)
    //   - endDate doit être Timestamp et > request.time + 8h (tes rules)
    // - sellerId obligatoire
    // - status = "active"
    // - on évite NSNull(); on omet les champs inutiles

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

        let now = Date()
        let nowTs = Timestamp(date: now)

        // ✅ Pour être cohérent avec le reste du projet:
        // même si c’est "free listing", on donne un cardItemId artificiel (string) pour éviter les soucis d’updates/immutables plus tard.
        let freeCardItemId = UUID().uuidString

        var data: [String: Any] = [
            "title": cleanTitle,
            "type": (type == .auction) ? "auction" : "fixedPrice",
            "status": "active",
            "createdAt": nowTs,
            "updatedAt": nowTs,
            "sellerId": user.uid,
            "cardItemId": freeCardItemId,
            "bidCount": 0
        ]

        if let descOrNil {
            data["descriptionText"] = descOrNil
        }
        // sinon: on omet complètement descriptionText

        if type == .fixedPrice {
            guard let p = buyNowPriceCAD, p > 0 else {
                throw NSError(
                    domain: "MarketplaceRepository",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Entre un prix valide (ex: 25)."]
                )
            }
            data["buyNowPriceCAD"] = p
            // rien d’autre pour fixedPrice
        } else {
            // auction
            guard let endDate else {
                throw NSError(
                    domain: "MarketplaceRepository",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Un encan doit avoir une date de fin."]
                )
            }

            // Tes rules: minimum 8h strict
            let minEnd = now.addingTimeInterval(8 * 60 * 60 + 10 * 60) // ✅ +10 min buffer anti-décalage horloge
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

            // ✅ CRUCIAL: currentBidCAD DOIT être number >= startingBidCAD
            data["startingBidCAD"] = start
            data["currentBidCAD"] = start
            data["endDate"] = Timestamp(date: endDate)
        }

        try await db.collection("listings").addDocument(data: data)
    }

    // MARK: - STATUS / DELETE

    func setListingStatus(listingId: String, status: String) async throws {
        try await db.collection("listings").document(listingId).updateData([
            "status": status,
            "updatedAt": Timestamp(date: Date())
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
            "updatedAt": Timestamp(date: Date())
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
                // si tu veux interdire de retirer le prix, tu peux throw ici.
                data["buyNowPriceCAD"] = FieldValue.delete()
            }
        } else {
            // auction
            if bidCount == 0 {
                if let s = startingBidCAD, s >= 0 {
                    data["startingBidCAD"] = s
                    // ⚠️ on ne touche pas currentBidCAD ici (rules owner updates l’interdisent souvent)
                } else {
                    data["startingBidCAD"] = FieldValue.delete()
                }
            }
        }

        try await db.collection("listings").document(listingId).updateData(data)
    }
}

