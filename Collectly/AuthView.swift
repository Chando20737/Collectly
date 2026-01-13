//
//  AuthView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import FirebaseAuth

struct AuthView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .signIn

    @State private var email: String = ""
    @State private var password: String = ""

    // ✅ Username (signup seulement) — sans "." (lettres/chiffres/_)
    @State private var username: String = ""

    @State private var isWorking = false
    @State private var errorText: String?

    // ✅ Reset password UI
    @State private var isResettingPassword = false
    @State private var resetInfoMessage: String?
    @State private var showResetAlert = false

    private let usersService = UsersService()

    enum Mode: String {
        case signIn = "Connexion"
        case signUp = "Créer un compte"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        Text("Se connecter").tag(Mode.signIn)
                        Text("Créer un compte").tag(Mode.signUp)
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .signUp {
                    Section("Nom d’utilisateur") {
                        TextField("username (ex: eric_123)", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)

                        Text("3-30 caractères. Lettres, chiffres et _")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Compte") {
                    TextField("Courriel", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)

                    SecureField("Mot de passe", text: $password)

                    // ✅ Mot de passe oublié (connexion seulement)
                    if mode == .signIn {
                        Button {
                            resetPassword()
                        } label: {
                            HStack(spacing: 8) {
                                if isResettingPassword {
                                    ProgressView()
                                } else {
                                    Image(systemName: "key.fill")
                                }
                                Text("Mot de passe oublié ?")
                            }
                        }
                        .disabled(isWorking || isResettingPassword || email.trimmed.isEmpty)
                        .foregroundStyle(.blue)
                    }
                }

                if let errorText {
                    Section("Erreur") {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking {
                                ProgressView()
                            } else {
                                Text(mode == .signIn ? "Se connecter" : "Créer le compte")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)

                    Button("Fermer") {
                        dismiss()
                    }
                    .foregroundStyle(.secondary)
                    .disabled(isWorking || isResettingPassword)
                }
            }
            .navigationTitle(mode.rawValue)
            .alert("Réinitialisation du mot de passe", isPresented: $showResetAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(resetInfoMessage ?? "Si le courriel existe, un lien a été envoyé.")
            }
        }
    }

    private var canSubmit: Bool {
        if isWorking || isResettingPassword { return false }
        if email.trimmed.isEmpty || password.trimmed.isEmpty { return false }
        if mode == .signUp {
            return !username.trimmed.isEmpty
        }
        return true
    }

    private func submit() {
        errorText = nil
        isWorking = true

        let cleanEmail = email.trimmed
        let cleanPass = password

        Task {
            do {
                if mode == .signIn {
                    _ = try await Auth.auth().signIn(withEmail: cleanEmail, password: cleanPass)
                } else {
                    _ = try await Auth.auth().createUser(withEmail: cleanEmail, password: cleanPass)

                    // ✅ Crée profil + réserve username (immuable)
                    try await usersService.createProfileWithUsername(username: username.trimmed)
                }

                await MainActor.run {
                    isWorking = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorText = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Password reset

    private func resetPassword() {
        errorText = nil
        isResettingPassword = true

        let cleanEmail = email.trimmed
        guard !cleanEmail.isEmpty else {
            isResettingPassword = false
            errorText = "Entre ton courriel pour recevoir le lien."
            return
        }

        Task {
            do {
                try await Auth.auth().sendPasswordReset(withEmail: cleanEmail)
                await MainActor.run {
                    isResettingPassword = false
                    resetInfoMessage = "Si un compte existe pour \(cleanEmail), un courriel a été envoyé."
                    showResetAlert = true
                }
            } catch {
                await MainActor.run {
                    isResettingPassword = false
                    // Souvent Firebase renvoie des erreurs détaillées; on les affiche.
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
