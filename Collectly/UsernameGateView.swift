//
//  UsernameGateView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-11.
//
import SwiftUI
import FirebaseAuth

struct UsernameGateView: View {
    let onDone: () -> Void

    @State private var username: String = ""
    @State private var isWorking = false
    @State private var errorText: String?

    private let usersService = UsersService()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choisis ton nom d’utilisateur")
                            .font(.headline)

                        Text("Tu en as besoin pour apparaître comme vendeur dans la Marketplace.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Nom d’utilisateur") {
                    TextField("ex: eric_123", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .onChange(of: username) { _, newValue in
                            // 1) enlève espaces
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            // 2) garde seulement [A-Za-z0-9_]
                            let filtered = trimmed.filter { ch in
                                ch.isLetter || ch.isNumber || ch == "_"
                            }
                            // 3) max 20 chars
                            let capped = String(filtered.prefix(20))

                            if capped != newValue {
                                username = capped
                            }
                        }

                    HStack {
                        Text("3–20 caractères. Lettres, chiffres et _")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(username.count)/20")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(username.count >= 20 ? .orange : .secondary)
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
                                Text("Continuer")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)

                    Button("Se déconnecter", role: .destructive) {
                        do {
                            try Auth.auth().signOut()
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                    .disabled(isWorking)
                }
            }
            .navigationTitle("Profil")
        }
    }

    private var canSubmit: Bool {
        if isWorking { return false }
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidUsername(u)
    }

    private func submit() {
        errorText = nil
        isWorking = true

        let clean = username.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                try await usersService.createProfileWithUsername(username: clean)
                await MainActor.run {
                    isWorking = false
                    onDone()
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func isValidUsername(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 20 else { return false }
        return s.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "_"
        }
    }
}

