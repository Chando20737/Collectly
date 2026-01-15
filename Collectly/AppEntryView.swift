//
//  AppEntryView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import FirebaseAuth

/// ✅ Objectif:
/// - Toujours afficher RootTabView
/// - Si connecté mais pas de username -> afficher un sheet non bloquant (Plus tard)
struct AppEntryView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var isChecking = false
    @State private var showUsernameGate = false
    @State private var errorText: String? = nil

    private let usersService = UsersService()

    var body: some View {
        RootTabView()
            // ✅ Plus fiable que onAppear/onChange : se déclenche quand uid change
            .task(id: session.user?.uid) {
                await checkUsernameIfNeeded(force: true)
            }
            .sheet(isPresented: $showUsernameGate) {
                UsernameGateSheet(
                    errorText: errorText,
                    onDone: {
                        // ✅ fermer tout de suite
                        showUsernameGate = false
                        errorText = nil

                        // puis recheck (au cas où)
                        Task { await checkUsernameIfNeeded(force: true) }
                    },
                    onLater: {
                        showUsernameGate = false
                    }
                )
            }
    }

    @MainActor
    private func checkUsernameIfNeeded(force: Bool = false) async {
        // pas connecté -> pas de gate
        guard session.user != nil else {
            showUsernameGate = false
            return
        }

        if isChecking { return }
        if !force, showUsernameGate { return }

        isChecking = true
        errorText = nil

        let uid = session.user?.uid ?? "nil"
        print("🔎 Username check started. uid=\(uid)")

        do {
            // 1) Premier check
            let existing1 = try await usersService.getCurrentUsername()
            let has1 = !(existing1?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            print("🔎 Username check #1 result: \(existing1 ?? "nil") (has=\(has1))")

            if has1 {
                isChecking = false
                showUsernameGate = false
                return
            }

            // 2) Retry (timing post-signup)
            try? await Task.sleep(nanoseconds: 450_000_000) // 0.45s

            let existing2 = try await usersService.getCurrentUsername()
            let has2 = !(existing2?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            print("🔎 Username check #2 result: \(existing2 ?? "nil") (has=\(has2))")

            isChecking = false
            showUsernameGate = (has2 == false)

        } catch {
            // ✅ Ne pas forcer le gate sur une erreur temporaire
            print("⚠️ Username check error: \(error.localizedDescription)")
            isChecking = false
            errorText = error.localizedDescription
            showUsernameGate = false
        }
    }
}

/// ✅ Wrapper: ajoute "Plus tard" dans la barre
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
            .navigationTitle("Profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Plus tard") { onLater() }
                }
            }
        }
    }
}
