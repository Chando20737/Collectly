//
//  ProfileView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct ProfileView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var showAuth = false
    @State private var debugMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Compte") {
                    if let user = session.user {
                        Text(user.email ?? "Utilisateur")
                            .foregroundStyle(.secondary)

                        Text("État: connecté")
                            .foregroundStyle(.secondary)

                        Button("Se déconnecter", role: .destructive) {
                            // ✅ session.signOut() ne lance pas d'erreur -> pas de try/catch
                            session.signOut()
                        }
                    } else {
                        Text("Non connecté")
                            .foregroundStyle(.secondary)

                        Text("État: déconnecté")
                            .foregroundStyle(.secondary)

                        Button("Se connecter / Créer un compte") {
                            showAuth = true
                        }
                    }
                }

                Section("Debug Firestore") {
                    Button("Test Firestore (écrire un document)") {
                        testFirestoreWrite()
                    }

                    if let debugMessage {
                        Text(debugMessage)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Profil")
            .sheet(isPresented: $showAuth) {
                AuthView()
            }
        }
    }

    private func testFirestoreWrite() {
        debugMessage = "Test en cours…"

        let db = Firestore.firestore()
        db.collection("debug").addDocument(data: [
            "createdAt": Timestamp(date: Date()),
            "message": "hello from Collectly",
            "uid": session.user?.uid ?? "nil"
        ]) { error in
            if let error {
                debugMessage = "❌ Firestore write failed: \(error.localizedDescription)"
                print("❌ Firestore write failed:", error)
            } else {
                debugMessage = "✅ Firestore write OK (collection debug)"
                print("✅ Firestore write OK (collection debug)")
            }
        }
    }
}

