//
//  UsernameGateView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-11.
//
import SwiftUI
import FirebaseAuth

struct UsernameGateView: View {
    @EnvironmentObject private var session: SessionStore

    let onDone: () -> Void

    @State private var username: String = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var isLoading = true

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
                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Vérification du profil…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("ex: eric_123", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .onChange(of: username) { _, newValue in
                                let cleaned = UsersService.normalizeUsername(newValue)
                                let capped = String(cleaned.prefix(20))
                                if capped != newValue { username = capped }
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
                            try session.signOut()
                            onDone()
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                    .disabled(isWorking)
                }
            }
            .navigationTitle("Profil")
            .task {
                await preloadAndMaybeSkip()
            }
        }
    }

    private var canSubmit: Bool {
        if isWorking || isLoading { return false }
        let u = UsersService.normalizeUsername(username)
        return UsersService.isValidUsername(u)
    }

    @MainActor
    private func preloadAndMaybeSkip() async {
        errorText = nil
        isLoading = true
        defer { isLoading = false }

        guard Auth.auth().currentUser != nil else { return }

        do {
            // ✅ si username existe déjà (Firestore usernameLower ou username), on sort direct
            if let existing = try await usersService.getCurrentUsername(),
               !existing.isEmpty {
                onDone()
                return
            }

            // fallback displayName
            if let dn = Auth.auth().currentUser?.displayName,
               !dn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {

                let normalized = UsersService.normalizeUsername(dn)
                if UsersService.isValidUsername(normalized) {
                    // backfill si possible
                    try? await usersService.createProfileWithUsername(username: normalized)
                    await session.refreshUser()
                    onDone()
                    return
                }
            }

        } catch {
            errorText = error.localizedDescription
        }
    }

    private func submit() {
        errorText = nil
        isWorking = true

        let clean = UsersService.normalizeUsername(username)

        Task {
            do {
                // Race condition: si déjà défini, on sort
                if let existing = try await usersService.getCurrentUsername(),
                   !existing.isEmpty {
                    await MainActor.run {
                        isWorking = false
                        onDone()
                    }
                    return
                }

                try await usersService.createProfileWithUsername(username: clean)
                await session.refreshUser()

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
}
