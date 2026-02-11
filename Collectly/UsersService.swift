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
    case permissionDenied
    case firestore(String)

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
        case .permissionDenied:
            return "Permissions insuffisantes (Firestore). Vérifie les Rules pour /users et /usernames."
        case .firestore(let msg):
            return msg
        }
    }
}

final class UsersService {

    private let db = Firestore.firestore()

    // MARK: - Public API

    /// ✅ Retourne le username actuel si présent.
    /// - Priorité: usernameLower
    /// - Fallback: username (et backfill usernameLower automatiquement si manquant)
    func getCurrentUsername() async throws -> String? {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw UsersServiceError.notSignedIn
        }

        let doc = try await db.collection("users").document(uid).getDocument()
        let data = doc.data() ?? [:]

        let uLower = (data["usernameLower"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !uLower.isEmpty {
            return Self.normalizeUsername(uLower)
        }

        let u = (data["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !u.isEmpty {
            let normalized = Self.normalizeUsername(u)

            // ✅ Backfill usernameLower si absent (utile pour tes anciens users)
            try? await db.collection("users").document(uid).setData([
                "usernameLower": normalized,
                "updatedAt": Timestamp(date: Date())
            ], merge: true)

            return normalized
        }

        return nil
    }

    func currentUserHasUsername() async throws -> Bool {
        let u = try await getCurrentUsername()
        return (u ?? "").isEmpty == false
    }

    func createProfileWithUsername(username: String) async throws {
        guard let user = Auth.auth().currentUser else {
            throw UsersServiceError.notSignedIn
        }

        let normalized = Self.normalizeUsername(username)
        guard Self.isValidUsername(normalized) else { throw UsersServiceError.invalidUsername }

        try await setUsername(uid: user.uid, username: normalized)
        try await setAuthDisplayName(normalized)
    }

    func getUsername(uid: String) async throws -> String? {
        let doc = try await db.collection("users").document(uid).getDocument()
        let data = doc.data() ?? [:]
        return (data["usernameLower"] as? String) ?? (data["username"] as? String)
    }

    // MARK: - Core (username immuable)

    func setUsername(uid: String, username: String) async throws {

        let normalized = Self.normalizeUsername(username)
        guard Self.isValidUsername(normalized) else { throw UsersServiceError.invalidUsername }

        let usersRef = db.collection("users").document(uid)
        let usernamesRef = db.collection("usernames").document(normalized)

        do {
            try await runTransactionAsync { transaction, errorPointer in
                do {
                    // 1) Username déjà défini? (immuable)
                    let userSnap = try transaction.getDocument(usersRef)
                    if userSnap.exists {
                        let data = userSnap.data() ?? [:]
                        let existing = ((data["usernameLower"] as? String) ?? (data["username"] as? String) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)

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

                    let now = Timestamp(date: Date())

                    // 3) users/{uid}
                    transaction.setData([
                        "uid": uid,
                        "username": normalized,
                        "usernameLower": normalized,
                        "updatedAt": now,
                        "createdAt": now
                    ], forDocument: usersRef, merge: true)

                    // 4) usernames/{normalized}
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
        } catch {
            let ns = error as NSError
            if ns.domain.contains("FIRFirestoreErrorDomain"), ns.code == 7 {
                throw UsersServiceError.permissionDenied
            }
            throw error
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

    // MARK: - Auth displayName

    @MainActor
    private func setAuthDisplayName(_ usernameLower: String) async throws {
        guard let user = Auth.auth().currentUser else { throw UsersServiceError.notSignedIn }

        let change = user.createProfileChangeRequest()
        change.displayName = usernameLower
        try await change.commitChanges()

        // reload pour reflet immédiat
        try? await user.reload()
    }

    // MARK: - Helpers (utilisés par tes Views)

    static func normalizeUsername(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.filter { ch in
            ch.isLetter || ch.isNumber || ch == "_"
        }
    }

    static func isValidUsername(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 20 else { return false }
        return s.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "_"
        }
    }
}
