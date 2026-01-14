//
//  UserProfileService.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-14.
//
import Foundation
import FirebaseAuth
import FirebaseFirestore

enum UserProfileError: LocalizedError {
    case notSignedIn
    case invalidUsername

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Utilisateur non connecté."
        case .invalidUsername:
            return "Nom d’utilisateur invalide. Utilise 3–30 caractères: lettres, chiffres et _."
        }
    }
}

final class UserProfileService {

    private let db = Firestore.firestore()

    func saveUsername(_ username: String) async throws {
        guard let user = Auth.auth().currentUser else { throw UserProfileError.notSignedIn }

        let cleaned = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard Self.isValidUsername(cleaned) else {
            throw UserProfileError.invalidUsername
        }

        // ✅ IMPORTANT: docId = uid (match rules)
        let ref = db.collection("users").document(user.uid)

        let payload: [String: Any] = [
            "username": cleaned,
            "updatedAt": Timestamp(date: Date())
        ]

        // merge:true => crée si inexistant, sinon update
        try await ref.setData(payload, merge: true)
    }

    static func isValidUsername(_ u: String) -> Bool {
        guard u.count >= 3 && u.count <= 30 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        return u.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

