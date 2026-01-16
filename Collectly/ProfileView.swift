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

    // ✅ NOUVEAU: évite l’effet “ça redemande”
    @State private var isLoadingUsername: Bool = false

    // ✅ Supprimer compte
    @State private var showDeleteAccountConfirm: Bool = false
    @State private var isDeletingAccount: Bool = false

    private let db = Firestore.firestore()

    // Aligné sur tes rules actuelles: ^[A-Za-z0-9_]+$
    private let minUsernameLength = 3
    private let maxUsernameLength = 20

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

                        // ✅ Pendant le chargement: on ne montre PAS le champ
                        // -> évite l’impression que l’app “redemande”
                        if isLoadingUsername {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Chargement du username…")
                                    .foregroundStyle(.secondary)
                            }
                        } else if hasUsername {
                            HStack {
                                Text("Username")
                                Spacer()
                                Text(username)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            // ✅ RETIRÉ: "✅ Username défini." (inutile)

                        } else {
                            TextField("Nom d’utilisateur", text: $username)
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

                            Button(isSavingUsername ? "Enregistrement…" : "Enregistrer") {
                                Task { await saveUsernameOnce() }
                            }
                            .disabled(isSavingUsername || !isUsernameValid(username))
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

                        // ✅ Nouveau: Supprimer mon compte (sous "Modifier mon mot de passe")
                        Button(role: .destructive) {
                            showDeleteAccountConfirm = true
                        } label: {
                            if isDeletingAccount {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Suppression du compte…")
                                }
                            } else {
                                Text("Supprimer mon compte")
                            }
                        }
                        .disabled(isDeletingAccount)
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
            .alert("Supprimer le compte", isPresented: $showDeleteAccountConfirm) {
                Button("Annuler", role: .cancel) { }
                Button("Supprimer", role: .destructive) {
                    Task { await deleteAccountConfirmed() }
                }
            } message: {
                Text("Es-tu certain de vouloir supprimer ton compte? Cette action est irréversible.")
            }
        }
    }

    // MARK: - Username helpers (alignés aux Rules)

    private func sanitizeUsername(_ input: String) -> String {
        let lowered = input.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        return String(lowered.filter { allowed.contains($0) })
    }

    private func isUsernameValid(_ u: String) -> Bool {
        let v = u.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.count >= minUsernameLength && v.count <= maxUsernameLength
    }

    // MARK: - Load profile

    private func loadProfile() {
        errorText = nil
        successText = nil

        guard let uid = session.user?.uid else {
            resetLocalState()
            return
        }

        // ✅ On passe en mode loading pour éviter l’effet “ça redemande”
        isLoadingUsername = true

        // Fallback immédiat: Auth.displayName (si dispo)
        if let dn = Auth.auth().currentUser?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dn.isEmpty {
            let normalized = sanitizeUsername(dn)
            if isUsernameValid(normalized) {
                username = normalized
                hasUsername = true
            }
        }

        db.collection("users").document(uid).getDocument { snap, err in
            DispatchQueue.main.async {
                self.isLoadingUsername = false

                if let err {
                    // IMPORTANT: ne plus ignorer l’erreur
                    self.errorText = err.localizedDescription
                    // On garde le fallback displayName si on l’avait
                    return
                }

                let data = snap?.data() ?? [:]
                let current = (data["username"] as? String) ?? ""
                let normalized = self.sanitizeUsername(current)

                if !normalized.isEmpty && self.isUsernameValid(normalized) {
                    self.username = normalized
                    self.hasUsername = true
                    return
                }

                // Si Firestore vide mais displayName existe -> backfill
                if let dn = Auth.auth().currentUser?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !dn.isEmpty {
                    let dnNorm = self.sanitizeUsername(dn)
                    if self.isUsernameValid(dnNorm) {
                        self.username = dnNorm
                        self.hasUsername = true
                        Task { await self.backfillUsernameIfNeeded(uid: uid, username: dnNorm) }
                        return
                    }
                }

                // Rien -> le champ apparait seulement maintenant
                self.username = ""
                self.hasUsername = false
            }
        }
    }

    @MainActor
    private func backfillUsernameIfNeeded(uid: String, username: String) async {
        do {
            try await runUsernameTransaction(uid: uid, newUsername: username)
        } catch {
            // silencieux (optionnel)
        }
    }

    private func resetLocalState() {
        username = ""
        hasUsername = false
        errorText = nil
        successText = nil
        isSavingUsername = false
        isSendingPasswordReset = false
        isLoadingUsername = false

        showDeleteAccountConfirm = false
        isDeletingAccount = false
    }

    // MARK: - Save username (set once)

    private func saveUsernameOnce() async {
        errorText = nil
        successText = nil

        guard let uid = session.user?.uid else {
            errorText = "Utilisateur non connecté."
            return
        }

        let newName = sanitizeUsername(username.trimmingCharacters(in: .whitespacesAndNewlines))
        guard isUsernameValid(newName) else {
            errorText = "Nom d’utilisateur invalide. Utilise 3–20 caractères: lettres, chiffres et _."
            return
        }

        isSavingUsername = true
        defer { isSavingUsername = false }

        do {
            try await runUsernameTransaction(uid: uid, newUsername: newName)

            // Écrire aussi dans Auth.displayName
            if let user = Auth.auth().currentUser {
                let change = user.createProfileChangeRequest()
                change.displayName = newName
                try await change.commitChanges()
            }

            await MainActor.run {
                username = newName
                hasUsername = true
                successText = "Nom d’utilisateur enregistré."
            }
        } catch {
            await MainActor.run {
                errorText = humanizeProfileError(error)
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

    private func humanizeProfileError(_ error: Error) -> String {
        let ns = error as NSError

        if ns.domain.contains("FIRFirestoreErrorDomain") && ns.code == 7 {
            return "Permissions insuffisantes (Firestore). Vérifie tes Rules pour /users et /usernames."
        }

        if ns.domain == "Profile" && ns.code == 409 {
            return ns.localizedDescription
        }

        return error.localizedDescription
    }

    // MARK: - Password reset

    private func sendPasswordReset(email: String?) {
        guard let email else { return }

        errorText = nil
        successText = nil
        isSendingPasswordReset = true

        Auth.auth().sendPasswordReset(withEmail: email) { error in
            DispatchQueue.main.async {
                self.isSendingPasswordReset = false

                if let error {
                    self.errorText = error.localizedDescription
                } else {
                    self.successText = "Courriel de réinitialisation envoyé."
                }
            }
        }
    }

    // MARK: - Delete account

    private func deleteAccountConfirmed() async {
        errorText = nil
        successText = nil

        guard session.user != nil else {
            errorText = "Utilisateur non connecté."
            return
        }

        isDeletingAccount = true
        defer { isDeletingAccount = false }

        // ⚠️ MVP: on supprime le compte Auth.
        // IMPORTANT: pour supprimer aussi les docs Firestore (users/uid, usernames/xxx, listings, etc.)
        // c’est fortement recommandé via Cloud Functions (admin privileges).
        do {
            try await Auth.auth().currentUser?.delete()
            await MainActor.run {
                successText = "Compte supprimé."
                resetLocalState()
            }
        } catch {
            await MainActor.run {
                // Cas fréquent: Firebase exige une "recent login" -> il faut re-auth.
                errorText = humanizeDeleteAccountError(error)
            }
        }
    }

    private func humanizeDeleteAccountError(_ error: Error) -> String {
        let ns = error as NSError
        // FIRAuthErrorDomain: 17014 = requires recent login (souvent)
        if ns.domain == AuthErrorDomain, ns.code == AuthErrorCode.requiresRecentLogin.rawValue {
            return "Pour supprimer ton compte, tu dois te reconnecter (sécurité Firebase). Déconnecte-toi puis reconnecte-toi, et réessaie."
        }
        return error.localizedDescription
    }
}
