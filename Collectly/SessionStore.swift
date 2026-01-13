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
        // État initial
        self.user = Auth.auth().currentUser

        // 🔥 Écoute les changements de connexion/déconnexion
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
        // Le listener mettra user=nil automatiquement
    }
}
