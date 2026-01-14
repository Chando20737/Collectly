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

    @State private var errorText: String?
    @State private var successText: String?

    @State private var username: String = ""
    @State private var hasUsername: Bool = false

    @State private var isSavingUsername: Bool = false
    @State private var isSendingPasswordReset: Bool = false

    private let db = Firestore.firestore()

    var body: some View {
        NavigationStack {
            Form {

                // MARK: - Compte
                Section("Compte") {
                    if let user = session.user {

                        Text(user.email ?? "Utilisateur")
                            .foregroundStyle(.secondary)

                        Text("État : connecté")
                            .foregroundStyle(.secondary)

                        Button("Se déconnecter", role: .destructive) {
                            do {
                                try session.signOut()
                                resetLocalState()
                            } catch {
                                errorText = error.localizedDescription
                            }
                        }

                    } else {
                        Text("Non connecté")
                            .foregroundStyle(.secondary)

                        Button("Se connecter / Créer un compte") {
                            showAuth = true
                        }
                    }
                }

                // MARK: - Nom d’utilisateur (set once)
                if session.user != nil {
                    Section("Nom d’utilisateur") {

                        TextField("Nom d’utilisateur", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(hasUsername)

                        if !hasUsername {
                            Button(isSavingUsername ? "Enregistrement…" : "Enregistrer") {
                                Task { await saveUsernameOnce() }
                            }
                            .disabled(isSavingUsername || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                // MARK: - Sécurité
                if let user = session.user {
                    Section("Sécurité") {

                        Button(isSendingPasswordReset
                               ? "Envoi en cours…"
                               : "Modifier mon mot de passe") {
                            sendPasswordReset(email: user.email)
                        }
                        .disabled(isSendingPasswordReset || user.email == nil)
                    }
                }

                // MARK: - Messages
                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }

                if let successText {
                    Section {
                        Text(successText)
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Profil")
            .sheet(isPresented: $showAuth) {
                AuthView()
            }
            .onAppear { loadProfile() }
            .onChange(of: session.user?.uid) { _, _ in loadProfile() }
        }
    }

    // MARK: - Load profile

    private func loadProfile() {
        errorText = nil
        successText = nil

        guard let uid = session.user?.uid else {
            resetLocalState()
            return
        }

        db.collection("users").document(uid).getDocument { snap, _ in
            let data = snap?.data() ?? [:]
            let current = (data["username"] as? String) ?? ""

            self.username = current
            self.hasUsername = !current.isEmpty
        }
    }

    private func resetLocalState() {
        username = ""
        hasUsername = false
        errorText = nil
        successText = nil
        isSavingUsername = false
        isSendingPasswordReset = false
    }

    // MARK: - Save username (set once)

    private func saveUsernameOnce() async {
        errorText = nil
        successText = nil

        guard let uid = session.user?.uid else {
            errorText = "Utilisateur non connecté."
            return
        }

        let newName = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            errorText = "Nom d’utilisateur invalide."
            return
        }

        isSavingUsername = true
        defer { isSavingUsername = false }

        do {
            try await runUsernameTransaction(uid: uid, newUsername: newName)
            await MainActor.run {
                hasUsername = true
                successText = "Nom d’utilisateur enregistré."
            }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
            }
        }
    }

    private func runUsernameTransaction(uid: String, newUsername: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in

            let userRef = db.collection("users").document(uid)
            let usernameRef = db.collection("usernames").document(newUsername)

            db.runTransaction({ transaction, errorPointer in
                do {
                    let userSnap = try transaction.getDocument(userRef)
                    let existing = (userSnap.data()?["username"] as? String) ?? ""
                    if !existing.isEmpty {
                        errorPointer?.pointee = NSError(
                            domain: "Profile",
                            code: 409,
                            userInfo: [NSLocalizedDescriptionKey: "Le nom d’utilisateur est déjà défini."]
                        )
                        return nil
                    }

                    let unameSnap = try transaction.getDocument(usernameRef)
                    if unameSnap.exists {
                        errorPointer?.pointee = NSError(
                            domain: "Profile",
                            code: 409,
                            userInfo: [NSLocalizedDescriptionKey: "Ce nom d’utilisateur est déjà pris."]
                        )
                        return nil
                    }

                    let now = Timestamp(date: Date())

                    transaction.setData([
                        "uid": uid,
                        "createdAt": now
                    ], forDocument: usernameRef, merge: false)

                    transaction.setData([
                        "username": newUsername,
                        "updatedAt": now
                    ], forDocument: userRef, merge: true)

                    return true
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }, completion: { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    // MARK: - Password reset

    private func sendPasswordReset(email: String?) {
        guard let email else { return }

        errorText = nil
        successText = nil
        isSendingPasswordReset = true

        Auth.auth().sendPasswordReset(withEmail: email) { error in
            isSendingPasswordReset = false

            if let error {
                errorText = error.localizedDescription
            } else {
                successText = "Courriel de réinitialisation envoyé."
            }
        }
    }
}
