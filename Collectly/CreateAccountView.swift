//
//  CreateAccountView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-11.
//
import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct CreateAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var username: String = ""

    @State private var isWorking = false
    @State private var errorText: String?

    private let minPasswordLength = 6
    private let minUsernameLength = 3
    private let maxUsernameLength = 20

    var body: some View {
        NavigationStack {
            Form {
                Section("Créer un compte") {
                    TextField("Courriel", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()

                    SecureField("Mot de passe", text: $password)

                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Nom d’utilisateur (username)", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: username) { _, newValue in
                                let cleaned = sanitizeUsername(newValue)
                                if cleaned != newValue { username = cleaned }
                                if username.count > maxUsernameLength {
                                    username = String(username.prefix(maxUsernameLength))
                                }
                            }

                        Text("3–20 caractères. Lettres, chiffres et _.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorText {
                    Section("Erreur") {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(isWorking ? "Création…" : "Créer mon compte") {
                        Task { await createAccount() }
                    }
                    .disabled(isWorking || !canSubmit)

                    Button("Annuler", role: .cancel) {
                        dismiss()
                    }
                    .disabled(isWorking)
                }
            }
            .navigationTitle("Créer un compte")
        }
    }

    // MARK: - Validation

    private var canSubmit: Bool {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = password
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return !e.isEmpty && p.count >= minPasswordLength && isUsernameValid(u)
    }

    private func sanitizeUsername(_ input: String) -> String {
        let lowered = input.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        return String(lowered.filter { allowed.contains($0) })
    }

    private func isUsernameValid(_ u: String) -> Bool {
        let v = u.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.count >= minUsernameLength && v.count <= maxUsernameLength
    }

    // MARK: - Create Account

    @MainActor
    private func createAccount() async {
        errorText = nil
        isWorking = true
        defer { isWorking = false }

        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = sanitizeUsername(username.trimmingCharacters(in: .whitespacesAndNewlines))

        guard isUsernameValid(normalizedUsername) else {
            errorText = "Username invalide. Utilise 3–20 caractères: lettres, chiffres et _."
            return
        }

        do {
            // 1) Firebase Auth
            let result = try await Auth.auth().createUser(withEmail: cleanEmail, password: password)
            let uid = result.user.uid
            let db = Firestore.firestore()

            // 2) Vérifier si username déjà pris
            let usernameRef = db.collection("usernames").document(normalizedUsername)
            let snap = try await usernameRef.getDocument()
            if snap.exists {
                try? await result.user.delete()
                errorText = "Ce username est déjà pris. Essaie-en un autre."
                return
            }

            // 3) Batch write /usernames + /users (même écriture)
            let userRef = db.collection("users").document(uid)
            let now = Timestamp(date: Date())

            let batch = db.batch()
            batch.setData([
                "uid": uid,
                "createdAt": now
            ], forDocument: usernameRef)

            batch.setData([
                "uid": uid,
                "email": cleanEmail,
                "username": normalizedUsername,
                "createdAt": now,
                "updatedAt": now
            ], forDocument: userRef, merge: true)

            try await batch.commit()

            // 4) displayName
            let change = result.user.createProfileChangeRequest()
            change.displayName = normalizedUsername
            try await change.commitChanges()

            // ✅ IMPORTANT: forcer SessionStore à republier le user (displayName)
            await session.refreshUser()

            dismiss()

        } catch {
            if let user = Auth.auth().currentUser {
                try? await user.delete()
            }
            errorText = humanError(error)
        }
    }

    private func humanError(_ error: Error) -> String {
        let ns = error as NSError

        if ns.domain == AuthErrorDomain {
            switch ns.code {
            case AuthErrorCode.emailAlreadyInUse.rawValue:
                return "Ce courriel est déjà utilisé."
            case AuthErrorCode.invalidEmail.rawValue:
                return "Courriel invalide."
            case AuthErrorCode.weakPassword.rawValue:
                return "Mot de passe trop faible (minimum \(minPasswordLength) caractères)."
            default:
                return error.localizedDescription
            }
        }

        if ns.domain.contains("FIRFirestoreErrorDomain") || ns.domain.contains("FirebaseFirestore") {
            if ns.code == 7 {
                return "Permissions insuffisantes (Firestore). Vérifie les Rules pour /users et /usernames."
            }
            return error.localizedDescription
        }

        return error.localizedDescription
    }
}

