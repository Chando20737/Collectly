//
//  UsersService.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-11.
//
import Foundation
import FirebaseAuth
import FirebaseFirestore

enum UsersServiceError: LocalizedError {
    case notSignedIn
    case invalidUsername
    case usernameTaken
    case usernameImmutable

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Utilisateur non connecté."
        case .invalidUsername:
            return "Nom d’utilisateur invalide (3–20, lettres/chiffres/_)."
        case .usernameTaken:
            return "Ce nom d’utilisateur est déjà pris."
        case .usernameImmutable:
            return "Ton username est déjà défini et ne peut pas être modifié."
        }
    }
}

final class UsersService {

    private let db = Firestore.firestore()

    // MARK: - Public API

    func currentUserHasUsername() async throws -> Bool {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw UsersServiceError.notSignedIn
        }

        let doc = try await db.collection("users").document(uid).getDocument()
        let data = doc.data() ?? [:]
        let u = (data["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !u.isEmpty
    }

    func createProfileWithUsername(username: String) async throws {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw UsersServiceError.notSignedIn
        }
        try await setUsername(uid: uid, username: username)
    }

    func getUsername(uid: String) async throws -> String? {
        let doc = try await db.collection("users").document(uid).getDocument()
        let data = doc.data() ?? [:]
        return data["username"] as? String
    }

    // MARK: - Core (username immuable)

    func setUsername(uid: String, username: String) async throws {
        let cleaned = Self.cleanUsername(username)
        guard Self.isValidUsername(cleaned) else { throw UsersServiceError.invalidUsername }

        let lower = cleaned.lowercased()

        let usersRef = db.collection("users").document(uid)
        let usernamesRef = db.collection("usernames").document(lower)

        try await runTransactionAsync { transaction, errorPointer in
            do {
                // 1) Username déjà défini? -> immuable
                let userSnap = try transaction.getDocument(usersRef)
                if userSnap.exists {
                    let existing = (userSnap.data()?["username"] as? String) ?? ""
                    if !existing.isEmpty {
                        errorPointer?.pointee = NSError(
                            domain: "UsersService",
                            code: 403,
                            userInfo: [NSLocalizedDescriptionKey: UsersServiceError.usernameImmutable.localizedDescription]
                        )
                        return nil
                    }
                }

                // 2) Username pris?
                let usernameSnap = try transaction.getDocument(usernamesRef)
                if usernameSnap.exists {
                    errorPointer?.pointee = NSError(
                        domain: "UsersService",
                        code: 409,
                        userInfo: [NSLocalizedDescriptionKey: UsersServiceError.usernameTaken.localizedDescription]
                    )
                    return nil
                }

                // 3) Écrit users/{uid}
                let now = Timestamp(date: Date())
                transaction.setData([
                    "uid": uid,
                    "username": cleaned,
                    "usernameLower": lower,
                    "createdAt": now
                ], forDocument: usersRef, merge: true)

                // 4) Réserve usernames/{lower}
                transaction.setData([
                    "uid": uid,
                    "createdAt": now
                ], forDocument: usernamesRef, merge: false)

                return true
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }
    }

    // MARK: - Transaction async/await

    private func runTransactionAsync(
        _ block: @escaping (Transaction, NSErrorPointer) -> Any?
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.db.runTransaction(block) { _, error in
                if let error {
                    let ns = error as NSError

                    if ns.domain == "UsersService", ns.code == 409 {
                        continuation.resume(throwing: UsersServiceError.usernameTaken)
                        return
                    }
                    if ns.domain == "UsersService", ns.code == 403 {
                        continuation.resume(throwing: UsersServiceError.usernameImmutable)
                        return
                    }

                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: ())
            }
        }
    }

    // MARK: - Helpers

    private static func cleanUsername(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.filter { !$0.isWhitespace }
    }

    private static func isValidUsername(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 20 else { return false }
        return s.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "_"
        }
    }
}

