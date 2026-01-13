//
//  AppEntryView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import FirebaseAuth

/// ✅ Objectif:
/// - Toujours afficher RootTabView (Marketplace + Ma collection + Profil)
/// - Ne jamais bloquer l’app sur AuthView au démarrage
/// - Si l’utilisateur est connecté mais n’a pas de username,
///   on peut afficher un sheet "Username" (non bloquant, avec bouton Plus tard)
struct AppEntryView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var isCheckingUsername = false
    @State private var hasUsername: Bool? = nil
    @State private var errorText: String? = nil

    @State private var showUsernameGate = false

    private let usersService = UsersService()

    var body: some View {
        RootTabView()
            // ✅ On fait la vérification en arrière-plan (si connecté),
            // mais on n’empêche pas l’utilisateur d’accéder à Marketplace.
            .onAppear {
                checkUsernameIfNeeded()
            }
            .onChange(of: session.user?.uid) { _, _ in
                // Quand on change de compte (login/logout), on reset et on revérifie
                hasUsername = nil
                errorText = nil
                showUsernameGate = false
                checkUsernameIfNeeded(force: true)
            }
            // ✅ Gate username en sheet (non bloquant)
            .sheet(isPresented: $showUsernameGate) {
                UsernameGateSheet(
                    errorText: errorText,
                    onDone: {
                        // après création, on revérifie
                        hasUsername = nil
                        errorText = nil
                        checkUsernameIfNeeded(force: true)
                    },
                    onLater: {
                        // L’utilisateur peut continuer à naviguer (Marketplace etc.)
                        showUsernameGate = false
                    }
                )
            }
    }

    private func checkUsernameIfNeeded(force: Bool = false) {
        // Pas connecté -> rien à vérifier
        guard session.user != nil else {
            hasUsername = nil
            showUsernameGate = false
            return
        }

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

                    // Si connecté mais pas de username -> on propose le gate (sheet)
                    self.showUsernameGate = (ok == false)
                }
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.hasUsername = false
                    self.isCheckingUsername = false

                    // En cas d’erreur, on affiche quand même le gate
                    self.showUsernameGate = true
                }
            }
        }
    }
}

/// ✅ Wrapper pour que UsernameGateView ait un bouton "Plus tard"
private struct UsernameGateSheet: View {
    let errorText: String?
    let onDone: () -> Void
    let onLater: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorText {
                    VStack(spacing: 8) {
                        Text("⚠️ \(errorText)")
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Divider()
                    }
                    .padding(.top, 12)
                }

                // Ton écran existant
                UsernameGateView(onDone: onDone)
                    .padding(.top, 8)
            }
            .navigationTitle("Créer un username")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Plus tard") { onLater() }
                }
            }
        }
    }
}
