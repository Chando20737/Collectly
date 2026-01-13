//
//  SessionStore.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation
import Combine
import FirebaseAuth

final class SessionStore: ObservableObject {

    @Published private(set) var user: User? = Auth.auth().currentUser

    private var handle: AuthStateDidChangeListenerHandle?

    init() {
        start()
    }

    deinit {
        // Évite les problèmes d’isolation actor dans deinit
        if let handle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
        handle = nil
    }

    func start() {
        // Évite d’ajouter 2 listeners
        guard handle == nil else { return }

        handle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            // On publie toujours sur le main thread pour SwiftUI
            DispatchQueue.main.async {
                self?.user = user
            }
        }
    }

    func stop() {
        if let handle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
        handle = nil
    }

    func signOut() {
        do {
            try Auth.auth().signOut()
            // user sera mis à jour par le listener, mais on peut aussi le mettre nil immédiatement
            DispatchQueue.main.async {
                self.user = nil
            }
        } catch {
            print("❌ SignOut error:", error)
        }
    }
}
