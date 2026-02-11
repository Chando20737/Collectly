import SwiftUI
import FirebaseAuth

#if canImport(FirebaseAppCheck)
import FirebaseAppCheck
#endif

/// Mini debug screen to validate Firebase Auth + App Check
struct FirebaseDebugView: View {

    @State private var userInfo: String = "Loading…"
    @State private var idTokenPreview: String = "—"
    @State private var errorText: String? = nil

    var body: some View {
        List {
            Section("Auth") {
                Text(userInfo)
                    .font(.footnote)
                    .textSelection(.enabled)
            }

            Section("ID Token (preview)") {
                Text(idTokenPreview)
                    .font(.caption2)
                    .textSelection(.enabled)
            }

#if canImport(FirebaseAppCheck)
            Section("App Check") {
                AppCheckSection()
            }
#endif

            if let errorText {
                Section("Error") {
                    Text(errorText)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Firebase Debug")
        .onAppear {
            refresh()
        }
    }

    private func refresh() {
        guard let user = Auth.auth().currentUser else {
            userInfo = "❌ Not signed in"
            return
        }

        userInfo = """
        ✅ Signed in
        uid: \(user.uid)
        email: \(user.email ?? "nil")
        displayName: \(user.displayName ?? "nil")
        isAnonymous: \(user.isAnonymous)
        providers: \(user.providerData.map { $0.providerID }.joined(separator: ", "))
        """

        // Modern async token fetch
        Task {
            do {
                let token = try await user.getIDToken()
                idTokenPreview = String(token.prefix(120)) + "…"
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

#if canImport(FirebaseAppCheck)
private struct AppCheckSection: View {

    @State private var tokenPreview: String = "—"
    @State private var errorText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tokenPreview)
                .font(.caption2)
                .textSelection(.enabled)

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            Button("Refresh App Check token") {
                refresh()
            }
            .buttonStyle(.bordered)
        }
        .onAppear {
            refresh()
        }
    }

    private func refresh() {
        AppCheck.appCheck().token(forcingRefresh: true) { token, error in
            if let token {
                tokenPreview = String(token.token.prefix(120)) + "…"
            } else if let error {
                errorText = error.localizedDescription
            }
        }
    }
}
#endif
