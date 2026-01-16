//
//  MarketplaceService.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import UIKit

enum MarketplaceError: LocalizedError {
    case notSignedIn
    case invalidCardId
    case alreadyListed
    case notOwner
    case cannotEditNonFixedPrice
    case cannotBuyOwnListing
    case listingNotActive
    case notFixedPrice
    case notAuction
    case auctionEnded
    case bidTooLow
    case missingUsernameProfile
    case invalidUsernameFormat
    case missingAuctionEndDate

    // ✅ Encans: minimum (8 heures)
    case auctionDurationTooShort

    // ✅ Prix fixe invalide
    case invalidFixedPrice

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Utilisateur non connecté."
        case .invalidCardId: return "Impossible d’identifier la carte."
        case .alreadyListed: return "Cette carte est déjà en vente."
        case .notOwner: return "Action non autorisée (pas le propriétaire)."
        case .cannotEditNonFixedPrice: return "Tu peux modifier le prix seulement pour une vente fixe."
        case .cannotBuyOwnListing: return "Tu ne peux pas acheter ta propre annonce."
        case .listingNotActive: return "Cette annonce n’est pas active."
        case .notFixedPrice: return "Cette annonce n’est pas une vente fixe."
        case .notAuction: return "Cette annonce n’est pas un encan."
        case .auctionEnded: return "Cet encan est terminé."
        case .bidTooLow: return "Ta mise est trop basse."
        case .missingUsernameProfile: return "Ton profil n’a pas de nom d’utilisateur. Va dans Profil pour le créer."
        case .invalidUsernameFormat: return "Ton nom d’utilisateur est invalide. Utilise seulement lettres, chiffres et _. (Pas de point.)"
        case .missingAuctionEndDate: return "Un encan doit avoir une date de fin."
        case .auctionDurationTooShort: return "Un encan doit durer au minimum 8 heures."
        case .invalidFixedPrice: return "Entre un prix valide (ex: 25)."
        }
    }
}

final class MarketplaceService {

    private let db = Firestore.firestore()
    private let storage = Storage.storage()

    // ✅ Minimum d’un encan: 8h
    private let minAuctionDurationSeconds: TimeInterval = 8 * 60 * 60

    // ✅ Petit buffer pour éviter les micro-décalages d’horloge (client vs request.time)
    private let driftBufferSeconds: TimeInterval = 120

    // MARK: - PUBLIC API

    func createListingFromCollection(
        from card: CardItem,
        title: String,
        description: String?,
        type: ListingType,
        buyNowPriceCAD: Double?,
        startingBidCAD: Double?,
        endDate: Date?
    ) async throws {

        guard let user = Auth.auth().currentUser else { throw MarketplaceError.notSignedIn }

        let cardItemId = card.id.uuidString
        guard cardItemId.count == 36 else { throw MarketplaceError.invalidCardId }

        if type == .auction {

            guard let endDate else { throw MarketplaceError.missingAuctionEndDate }

            let now = Date()
            // ✅ Minimum 8h + buffer
            if endDate.timeIntervalSince(now) < (minAuctionDurationSeconds + driftBufferSeconds) {
                throw MarketplaceError.auctionDurationTooShort
            }

            // ✅ NOUVEL ID à chaque fois (évite collisions)
            let ts = Int(Date().timeIntervalSince1970)
            let listingId = "\(user.uid)_\(cardItemId)_\(ts)"

            try await createNewListingDoc(
                listingId: listingId,
                card: card,
                title: title,
                description: description,
                type: .auction,
                buyNowPriceCAD: nil,
                startingBidCAD: startingBidCAD,
                endDate: endDate
            )

        } else {

            // ✅ fixedPrice: doc legacy (uid_cardId)
            let listingId = "\(user.uid)_\(cardItemId)"

            try await createOrUpdateFixedPriceLegacyDoc(
                listingId: listingId,
                card: card,
                title: title,
                description: description,
                buyNowPriceCAD: buyNowPriceCAD
            )
        }
    }

    // MARK: - BUY NOW (server time)

    func buyNow(listingId: String) async throws {
        guard let user = Auth.auth().currentUser else { throw MarketplaceError.notSignedIn }

        let buyerUsername = try await fetchUsernameOrThrow(uid: user.uid)

        let ref = db.collection("listings").document(listingId)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            db.runTransaction({ transaction, errorPointer in
                do {
                    let snap = try transaction.getDocument(ref)
                    guard snap.exists, let data = snap.data() else {
                        errorPointer?.pointee = NSError(
                            domain: "MarketplaceService",
                            code: 404,
                            userInfo: [NSLocalizedDescriptionKey: "Annonce introuvable."]
                        )
                        return nil
                    }

                    let sellerId = (data["sellerId"] as? String) ?? ""
                    if sellerId == user.uid {
                        errorPointer?.pointee = NSError(
                            domain: "MarketplaceService",
                            code: 403,
                            userInfo: [NSLocalizedDescriptionKey: MarketplaceError.cannotBuyOwnListing.localizedDescription]
                        )
                        return nil
                    }

                    let status = (data["status"] as? String) ?? ""
                    if status != "active" {
                        errorPointer?.pointee = NSError(
                            domain: "MarketplaceService",
                            code: 409,
                            userInfo: [NSLocalizedDescriptionKey: MarketplaceError.listingNotActive.localizedDescription]
                        )
                        return nil
                    }

                    let type = (data["type"] as? String) ?? ""
                    if type != "fixedPrice" {
                        errorPointer?.pointee = NSError(
                            domain: "MarketplaceService",
                            code: 400,
                            userInfo: [NSLocalizedDescriptionKey: MarketplaceError.notFixedPrice.localizedDescription]
                        )
                        return nil
                    }

                    let price = (data["buyNowPriceCAD"] as? Double) ?? 0

                    transaction.updateData([
                        "status": "sold",
                        "buyerId": user.uid,
                        "buyerUsername": buyerUsername,
                        "finalPriceCAD": price,
                        "soldAt": FieldValue.serverTimestamp(),
                        "updatedAt": FieldValue.serverTimestamp()
                    ], forDocument: ref)

                    return true
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }, completion: { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            })
        }
    }

    // MARK: - PLACE BID (server time)

    func placeBid(listingId: String, bidCAD: Double) async throws {
        guard let user = Auth.auth().currentUser else { throw MarketplaceError.notSignedIn }
        guard bidCAD > 0 else { throw MarketplaceError.bidTooLow }

        let bidderUsername = try await fetchUsernameOrThrow(uid: user.uid)

        let ref = db.collection("listings").document(listingId)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            db.runTransaction({ transaction, errorPointer in
                do {
                    let snap = try transaction.getDocument(ref)
                    guard snap.exists, let data = snap.data() else {
                        errorPointer?.pointee = NSError(
                            domain: "MarketplaceService",
                            code: 404,
                            userInfo: [NSLocalizedDescriptionKey: "Annonce introuvable."]
                        )
                        return nil
                    }

                    let sellerId = (data["sellerId"] as? String) ?? ""
                    if sellerId == user.uid {
                        errorPointer?.pointee = NSError(
                            domain: "MarketplaceService",
                            code: 403,
                            userInfo: [NSLocalizedDescriptionKey: MarketplaceError.cannotBuyOwnListing.localizedDescription]
                        )
                        return nil
                    }

                    let type = (data["type"] as? String) ?? ""
                    if type != "auction" {
                        errorPointer?.pointee = NSError(
                            domain: "MarketplaceService",
                            code: 400,
                            userInfo: [NSLocalizedDescriptionKey: MarketplaceError.notAuction.localizedDescription]
                        )
                        return nil
                    }

                    let status = (data["status"] as? String) ?? ""
                    if status != "active" {
                        errorPointer?.pointee = NSError(
                            domain: "MarketplaceService",
                            code: 409,
                            userInfo: [NSLocalizedDescriptionKey: MarketplaceError.listingNotActive.localizedDescription]
                        )
                        return nil
                    }

                    if let endTs = data["endDate"] as? Timestamp, endTs.dateValue() <= Date() {
                        errorPointer?.pointee = NSError(
                            domain: "MarketplaceService",
                            code: 410,
                            userInfo: [NSLocalizedDescriptionKey: MarketplaceError.auctionEnded.localizedDescription]
                        )
                        return nil
                    }

                    let current = (data["currentBidCAD"] as? Double)
                    let starting = (data["startingBidCAD"] as? Double) ?? 0
                    let minRequired = max(current ?? starting, starting)

                    if bidCAD <= minRequired {
                        errorPointer?.pointee = NSError(
                            domain: "MarketplaceService",
                            code: 422,
                            userInfo: [NSLocalizedDescriptionKey: MarketplaceError.bidTooLow.localizedDescription]
                        )
                        return nil
                    }

                    let bidCount = (data["bidCount"] as? Int) ?? 0
                    let newBidCount = bidCount + 1

                    transaction.updateData([
                        "currentBidCAD": bidCAD,
                        "bidCount": newBidCount,
                        "lastBidderId": user.uid,
                        "lastBidderUsername": bidderUsername,
                        "updatedAt": FieldValue.serverTimestamp()
                    ], forDocument: ref)

                    return true
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }, completion: { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            })
        }
    }

    // MARK: - UPDATE FIXED PRICE (optionnel)

    func updateFixedPriceListing(
        listingId: String,
        newTitle: String,
        newDescription: String?,
        newBuyNowPriceCAD: Double?
    ) async throws {

        guard let user = Auth.auth().currentUser else { throw MarketplaceError.notSignedIn }

        let docRef = db.collection("listings").document(listingId)
        let snap = try await docRef.getDocument()

        guard snap.exists, let data = snap.data() else { throw MarketplaceError.notOwner }
        guard (data["sellerId"] as? String) == user.uid else { throw MarketplaceError.notOwner }

        let type = (data["type"] as? String) ?? "fixedPrice"
        guard type == "fixedPrice" else { throw MarketplaceError.cannotEditNonFixedPrice }

        let cleanTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDesc = newDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc: String? = (cleanDesc?.isEmpty == true) ? nil : cleanDesc

        var updates: [String: Any] = [
            "title": cleanTitle,
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if let desc {
            updates["descriptionText"] = desc
        } else {
            updates["descriptionText"] = FieldValue.delete()
        }

        if let p = newBuyNowPriceCAD {
            updates["buyNowPriceCAD"] = p
        } else {
            updates["buyNowPriceCAD"] = FieldValue.delete()
        }

        try await docRef.updateData(updates)
    }

    // MARK: - END LISTING (manual)

    func endListing(listingId: String) async throws {
        guard let user = Auth.auth().currentUser else { throw MarketplaceError.notSignedIn }

        let ref = db.collection("listings").document(listingId)
        let snap = try await ref.getDocument()

        guard snap.exists, let data = snap.data() else { throw MarketplaceError.notOwner }
        guard (data["sellerId"] as? String) == user.uid else { throw MarketplaceError.notOwner }

        try await ref.updateData([
            "status": "ended",
            "endedAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }

    // MARK: - END LISTINGS FOR CARD (delete CardItem)

    func endListingIfExistsForDeletedCard(cardItemId: String) async {
        guard let user = Auth.auth().currentUser else { return }

        do {
            let snap = try await db.collection("listings")
                .whereField("sellerId", isEqualTo: user.uid)
                .whereField("cardItemId", isEqualTo: cardItemId)
                .getDocuments()

            guard !snap.documents.isEmpty else { return }

            let batch = db.batch()

            for doc in snap.documents {
                let data = doc.data()
                let status = (data["status"] as? String) ?? ""
                if status == "sold" || status == "ended" { continue }

                let type = (data["type"] as? String) ?? ""

                if type == "fixedPrice" {
                    if status == "active" || status == "paused" {
                        batch.updateData([
                            "status": "ended",
                            "endedAt": FieldValue.serverTimestamp(),
                            "updatedAt": FieldValue.serverTimestamp()
                        ], forDocument: doc.reference)
                    }
                }

                if type == "auction" {
                    if status == "active" {
                        let bidCount = (data["bidCount"] as? Int) ?? 0
                        if bidCount == 0 {
                            batch.updateData([
                                "status": "ended",
                                "endedAt": FieldValue.serverTimestamp(),
                                "updatedAt": FieldValue.serverTimestamp()
                            ], forDocument: doc.reference)
                        }
                    }
                }
            }

            try await batch.commit()
        } catch {
            print("⚠️ endListingIfExistsForDeletedCard error:", error.localizedDescription)
        }
    }

    // MARK: - INTERNALS (Create / Update fixedPrice legacy)

    private func createOrUpdateFixedPriceLegacyDoc(
        listingId: String,
        card: CardItem,
        title: String,
        description: String?,
        buyNowPriceCAD: Double?
    ) async throws {

        guard let user = Auth.auth().currentUser else { throw MarketplaceError.notSignedIn }

        let docRef = db.collection("listings").document(listingId)

        let sellerUsername = try await fetchUsernameOrThrow(uid: user.uid)
        guard Self.isValidUsernameForRules(sellerUsername) else { throw MarketplaceError.invalidUsernameFormat }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDesc = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc: String? = (cleanDesc?.isEmpty == true) ? nil : cleanDesc

        let existing = try await docRef.getDocument()

        if existing.exists, let data = existing.data() {
            let sellerId = (data["sellerId"] as? String) ?? ""
            guard sellerId == user.uid else { throw MarketplaceError.notOwner }

            let storedType = (data["type"] as? String) ?? "fixedPrice"
            guard storedType == "fixedPrice" else { throw MarketplaceError.cannotEditNonFixedPrice }

            let currentStatus = (data["status"] as? String) ?? "active"
            let nextStatus: String = (currentStatus == "sold" || currentStatus == "ended") ? "active" : currentStatus

            var updates: [String: Any] = [
                "title": cleanTitle,
                "updatedAt": FieldValue.serverTimestamp(),
                "sellerUsername": sellerUsername,
                "status": nextStatus
            ]

            if let desc {
                updates["descriptionText"] = desc
            } else {
                updates["descriptionText"] = FieldValue.delete()
            }

            if let buyNowPriceCAD {
                updates["buyNowPriceCAD"] = buyNowPriceCAD
            } else {
                updates["buyNowPriceCAD"] = FieldValue.delete()
            }

            applyGradingUpdates(from: card, to: &updates)

            try await docRef.updateData(updates)

            if let imageUrl = try await uploadListingImageIfNeeded(card: card, listingId: listingId, uid: user.uid) {
                try await docRef.updateData([
                    "imageUrl": imageUrl,
                    "updatedAt": FieldValue.serverTimestamp()
                ])
            }

            return
        }

        // ✅ Création initiale
        guard let price = buyNowPriceCAD, price > 0 else {
            throw MarketplaceError.invalidFixedPrice
        }

        var payload: [String: Any] = [
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp(),
            "sellerId": user.uid,
            "sellerUsername": sellerUsername,
            "cardItemId": card.id.uuidString,
            "title": cleanTitle,
            "type": "fixedPrice",
            "status": "active",
            "bidCount": 0,
            "buyNowPriceCAD": price
        ]

        if let desc { payload["descriptionText"] = desc }

        applyGradingPayload(from: card, to: &payload)

        try await docRef.setData(payload, merge: false)

        if let imageUrl = try await uploadListingImageIfNeeded(card: card, listingId: listingId, uid: user.uid) {
            try await docRef.updateData([
                "imageUrl": imageUrl,
                "updatedAt": FieldValue.serverTimestamp()
            ])
        }
    }

    private func createNewListingDoc(
        listingId: String,
        card: CardItem,
        title: String,
        description: String?,
        type: ListingType,
        buyNowPriceCAD: Double?,
        startingBidCAD: Double?,
        endDate: Date?
    ) async throws {

        guard let user = Auth.auth().currentUser else { throw MarketplaceError.notSignedIn }

        let docRef = db.collection("listings").document(listingId)

        let sellerUsername = try await fetchUsernameOrThrow(uid: user.uid)
        guard Self.isValidUsernameForRules(sellerUsername) else { throw MarketplaceError.invalidUsernameFormat }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDesc = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc: String? = (cleanDesc?.isEmpty == true) ? nil : cleanDesc

        let typeString: String = (type == .auction) ? "auction" : "fixedPrice"

        var payload: [String: Any] = [
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp(),
            "sellerId": user.uid,
            "sellerUsername": sellerUsername,
            "cardItemId": card.id.uuidString,
            "title": cleanTitle,
            "type": typeString,
            "status": "active",
            "bidCount": 0
        ]

        if let desc { payload["descriptionText"] = desc }

        if type == .fixedPrice {
            guard let p = buyNowPriceCAD, p > 0 else { throw MarketplaceError.invalidFixedPrice }
            payload["buyNowPriceCAD"] = p
        } else {
            guard let endDate else { throw MarketplaceError.missingAuctionEndDate }

            let nowDate = Date()
            if endDate.timeIntervalSince(nowDate) < (minAuctionDurationSeconds + driftBufferSeconds) {
                throw MarketplaceError.auctionDurationTooShort
            }

            let start = startingBidCAD ?? 0
            payload["startingBidCAD"] = start
            payload["currentBidCAD"] = start
            payload["endDate"] = Timestamp(date: endDate)
        }

        applyGradingPayload(from: card, to: &payload)

        try await docRef.setData(payload, merge: false)

        if let imageUrl = try await uploadListingImageIfNeeded(card: card, listingId: listingId, uid: user.uid) {
            try await docRef.updateData([
                "imageUrl": imageUrl,
                "updatedAt": FieldValue.serverTimestamp()
            ])
        }
    }

    // MARK: - Grading helpers

    private func applyGradingPayload(from card: CardItem, to payload: inout [String: Any]) {
        let gradingCompany = (card.gradingCompany ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let gradeValue = (card.gradeValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cert = (card.certificationNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let hasGradeInfo = !gradeValue.isEmpty || !gradingCompany.isEmpty || !cert.isEmpty
        let isGraded = (card.isGraded ?? false)

        payload["isGraded"] = (isGraded || hasGradeInfo)
        if !gradingCompany.isEmpty { payload["gradingCompany"] = gradingCompany }
        if !gradeValue.isEmpty { payload["gradeValue"] = gradeValue }
        if !cert.isEmpty { payload["certificationNumber"] = cert }
    }

    private func applyGradingUpdates(from card: CardItem, to updates: inout [String: Any]) {
        let gradingCompany = (card.gradingCompany ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let gradeValue = (card.gradeValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cert = (card.certificationNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let hasGradeInfo = !gradeValue.isEmpty || !gradingCompany.isEmpty || !cert.isEmpty
        let isGraded = (card.isGraded ?? false)

        updates["isGraded"] = (isGraded || hasGradeInfo)

        updates["gradingCompany"] = gradingCompany.isEmpty ? FieldValue.delete() : gradingCompany
        updates["gradeValue"] = gradeValue.isEmpty ? FieldValue.delete() : gradeValue
        updates["certificationNumber"] = cert.isEmpty ? FieldValue.delete() : cert
    }

    // MARK: - Username helpers

    private func fetchUsernameOrThrow(uid: String) async throws -> String {
        let doc = try await db.collection("users").document(uid).getDocument()
        let data = doc.data() ?? [:]
        let username = (data["username"] as? String) ?? ""
        let cleaned = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { throw MarketplaceError.missingUsernameProfile }
        return cleaned
    }

    private static func isValidUsernameForRules(_ u: String) -> Bool {
        guard u.count >= 3 && u.count <= 30 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        return u.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - IMAGE UPLOAD

    private func uploadListingImageIfNeeded(card: CardItem, listingId: String, uid: String) async throws -> String? {
        guard let data = card.frontImageData else { return nil }
        guard let uiImage = UIImage(data: data) else { return nil }
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.82) else { return nil }

        let path = "listings/\(uid)/\(listingId)/front.jpg"
        let ref = storage.reference().child(path)

        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        _ = try await ref.putDataAsync(jpegData, metadata: metadata)
        let url = try await ref.downloadURL()
        return url.absoluteString
    }
}
