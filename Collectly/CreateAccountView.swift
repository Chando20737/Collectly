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

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var username: String = ""

    @State private var isWorking = false
    @State private var errorText: String?

    // Ajuste si tu veux
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
                                // Nettoyage “live”
                                let cleaned = sanitizeUsername(newValue)
                                if cleaned != newValue { username = cleaned }
                                if username.count > maxUsernameLength {
                                    username = String(username.prefix(maxUsernameLength))
                                }
                            }

                        Text("3–20 caractères. Lettres, chiffres, . et _.")
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
        // lowercased + enlève espaces + garde caractères autorisés
        let lowered = input.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._")
        return String(lowered.filter { allowed.contains($0) })
    }

    private func isUsernameValid(_ u: String) -> Bool {
        guard u.count >= minUsernameLength && u.count <= maxUsernameLength else { return false }
        // interdit de commencer/finir par .
        if u.hasPrefix(".") || u.hasSuffix(".") { return false }
        return true
    }

    // MARK: - Create Account

    @MainActor
    private func createAccount() async {
        errorText = nil
        isWorking = true
        defer { isWorking = false }

        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            // 1) Firebase Auth: create user
            let result = try await Auth.auth().createUser(withEmail: cleanEmail, password: password)

            // 2) Set displayName (username)
            let change = result.user.createProfileChangeRequest()
            change.displayName = cleanUsername
            try await change.commitChanges()

            // 3) Store in Firestore users/{uid}
            let uid = result.user.uid
            let db = Firestore.firestore()
            try await db.collection("users").document(uid).setData([
                "uid": uid,
                "email": cleanEmail,
                "username": cleanUsername,
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ], merge: true)

            // ✅ Done
            dismiss()
        } catch {
            errorText = humanError(error)
        }
    }

    private func humanError(_ error: Error) -> String {
        let ns = error as NSError
        // Messages un peu plus “humains”
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
        return error.localizedDescription
    }
}

