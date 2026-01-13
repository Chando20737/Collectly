//
//  AppEntryView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import FirebaseAuth

struct AppEntryView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var isCheckingUsername = false
    @State private var hasUsername: Bool? = nil
    @State private var errorText: String? = nil

    private let usersService = UsersService()

    var body: some View {
        Group {
            // 1) Pas connecté -> Auth
            if session.user == nil {
                AuthView()
            } else {
                // 2) Connecté -> on vérifie username
                if isCheckingUsername || hasUsername == nil {
                    loadingView
                        .onAppear { checkUsernameIfNeeded() }
                } else if hasUsername == false {
                    // 3) Connecté mais pas de username -> Gate
                    UsernameGateView(onDone: {
                        // après création, on revérifie
                        hasUsername = nil
                        checkUsernameIfNeeded(force: true)
                    })
                } else {
                    // 4) Connecté + username OK -> App normale
                    RootTabView()
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Vérification du profil…")
                .foregroundStyle(.secondary)
            if let errorText {
                Text("❌ \(errorText)")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func checkUsernameIfNeeded(force: Bool = false) {
        if isCheckingUsername { return }
        if !force, hasUsername != nil { return }

        isCheckingUsername = true
        errorText = nil

        Task {
            do {
                let ok = try await usersService.currentUserHasUsername()
                await MainActor.run {
                    self.hasUsername = ok
                    self.isCheckingUsername = false
                }
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.hasUsername = false // fallback -> gate (safe)
                    self.isCheckingUsername = false
                }
            }
        }
    }
}
