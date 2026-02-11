//
//  DeepLinkRouter.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-13.
//
import Foundation
import Combine

@MainActor
final class DeepLinkRouter: ObservableObject {

    /// Quand cette valeur devient non-nil, l'app doit ouvrir directement cette annonce.
    @Published var openListingId: String? = nil

    // MARK: - Public

    /// Reçoit le userInfo d'une notification (tap) et tente d'en extraire un listingId.
    func handleNotificationUserInfo(_ userInfo: [AnyHashable: Any]) {

        // 1) Cas le plus simple: listingId au top-level
        if let id = extractString(userInfo["listingId"]), !id.isEmpty {
            openListingId = id
            return
        }

        // 2) Cas: data est un dictionnaire
        if let dict = userInfo["data"] as? [String: Any] {
            if let id = extractString(dict["listingId"]), !id.isEmpty {
                openListingId = id
                return
            }
            if let id = extractString(dict["listing_id"]), !id.isEmpty {
                openListingId = id
                return
            }
        }

        // 3) Cas: data est [String:String]
        if let dict = userInfo["data"] as? [String: String] {
            if let id = dict["listingId"], !id.isEmpty {
                openListingId = id
                return
            }
            if let id = dict["listing_id"], !id.isEmpty {
                openListingId = id
                return
            }
        }

        // 4) Cas: data est une string JSON
        if let jsonString = extractString(userInfo["data"]), !jsonString.isEmpty {
            if let dict = parseJSONStringToDict(jsonString) {
                if let id = extractString(dict["listingId"]), !id.isEmpty {
                    openListingId = id
                    return
                }
                if let id = extractString(dict["listing_id"]), !id.isEmpty {
                    openListingId = id
                    return
                }
            }
        }

        // 5) Parfois des clés custom arrivent au top-level en String
        // (ex: listing_id)
        if let id = extractString(userInfo["listing_id"]), !id.isEmpty {
            openListingId = id
            return
        }

        print("ℹ️ DeepLinkRouter: aucun listingId trouvé dans userInfo")
    }

    /// À appeler après avoir “consommé” le deep link (pour éviter la réouverture).
    func clear() {
        openListingId = nil
    }

    // MARK: - Helpers

    private func extractString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private func parseJSONStringToDict(_ s: String) -> [String: Any]? {
        let data = Data(s.utf8)
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: [])
            return json as? [String: Any]
        } catch {
            return nil
        }
    }
}

