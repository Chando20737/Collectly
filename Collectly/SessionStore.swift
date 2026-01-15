//
//  SessionStore.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation
import Combine
import FirebaseAuth

@MainActor
final class SessionStore: ObservableObject {

    @Published var user: FirebaseAuth.User? = nil

    private var handle: AuthStateDidChangeListenerHandle?

    init() {
        self.user = Auth.auth().currentUser

        handle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            self.user = user
            print("✅ Auth state changed. user = \(user?.uid ?? "nil")")
        }
    }

    deinit {
        if let handle { Auth.auth().removeStateDidChangeListener(handle) }
    }

    func signOut() throws {
        try Auth.auth().signOut()
        // listener va mettre user=nil
    }

    /// ✅ Permet de recharger l’utilisateur Firebase (displayName, etc.)
    func refreshUser() async {
        guard let u = Auth.auth().currentUser else {
            self.user = nil
            return
        }

        do {
            try await u.reload()
        } catch {
            // pas bloquant
            print("⚠️ refreshUser reload error: \(error.localizedDescription)")
        }

        self.user = Auth.auth().currentUser
        print("✅ Session refreshed. displayName=\(self.user?.displayName ?? "nil")")
    }
}
