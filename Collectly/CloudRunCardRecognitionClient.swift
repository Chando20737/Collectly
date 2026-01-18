//
//  CloudRunCardRecognitionClient.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-17.
//
import Foundation
import FirebaseAuth
import FirebaseAppCheck

// MARK: - Cloud Run Card Recognition Client

final class CloudRunCardRecognitionClient {

    static let shared = CloudRunCardRecognitionClient()

    // ✅ Ton URL Cloud Run (base)
    private let baseURL = URL(string: "https://collectly-card-recognition-804653235934.northamerica-northeast1.run.app")!

    // ✅ Endpoints possibles (au cas où ton backend n'est pas encore figé)
    // On essaie d'abord /recognizeCard, puis /recognize, puis / (root) en fallback.
    private let candidatePaths = ["/recognizeCard", "/recognize", "/"]

    private init() {}

    // Réponse attendue (flexible)
    struct RecognitionResponse: Decodable {
        let playerName: String?
        let cardYear: String?
        let companyName: String?
        let setName: String?
        let cardNumber: String?

        // optionnel
        let confidence: Double?
        let candidates: [Candidate]?

        struct Candidate: Decodable {
            let name: String?
            let confidence: Double?
        }
    }

    enum ClientError: Error, LocalizedError {
        case notAuthenticated
        case invalidURL
        case requestFailed(Int, String)
        case decodingFailed
        case noWorkingEndpoint
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Utilisateur non connecté (FirebaseAuth)."
            case .invalidURL:
                return "URL Cloud Run invalide."
            case .requestFailed(let code, let body):
                return "Cloud Run a répondu \(code): \(body)"
            case .decodingFailed:
                return "Impossible de décoder la réponse du serveur."
            case .noWorkingEndpoint:
                return "Aucun endpoint Cloud Run ne répond (vérifie les routes du service)."
            case .underlying(let msg):
                return msg
            }
        }
    }

    // MARK: Public API

    /// Envoie le texte OCR au service Cloud Run et retourne une suggestion (playerName, set, year, number, etc.)
    func recognize(ocrText: String, lines: [String]) async throws -> RecognitionResponse {
        let trimmed = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return RecognitionResponse(playerName: nil, cardYear: nil, companyName: nil, setName: nil, cardNumber: nil, confidence: nil, candidates: nil) }

        // ✅ 1) Firebase ID token
        let idToken = try await fetchFirebaseIDToken()

        // ✅ 2) Firebase App Check token
        let appCheckToken = try await fetchAppCheckToken()

        // Payload
        let payload: [String: Any] = [
            "ocrText": trimmed,
            "lines": lines
        ]

        // Essaie les endpoints (au cas où ton backend a une route différente)
        var lastError: Error?

        for path in candidatePaths {
            do {
                let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                return try await postJSON(url: url, idToken: idToken, appCheckToken: appCheckToken, payload: payload)
            } catch {
                lastError = error
                // on continue à essayer les autres paths
            }
        }

        if let lastError { throw lastError }
        throw ClientError.noWorkingEndpoint
    }

    // MARK: - Tokens

    private func fetchFirebaseIDToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw ClientError.notAuthenticated
        }

        return try await withCheckedThrowingContinuation { cont in
            user.getIDTokenForcingRefresh(true) { token, error in
                if let error {
                    cont.resume(throwing: ClientError.underlying("Erreur ID token: \(error.localizedDescription)"))
                } else if let token, !token.isEmpty {
                    cont.resume(returning: token)
                } else {
                    cont.resume(throwing: ClientError.underlying("ID token vide."))
                }
            }
        }
    }

    private func fetchAppCheckToken() async throws -> String {
        return try await withCheckedThrowingContinuation { cont in
            AppCheck.appCheck().token(forcingRefresh: true) { token, error in
                if let error {
                    cont.resume(throwing: ClientError.underlying("Erreur AppCheck token: \(error.localizedDescription)"))
                } else if let token = token?.token, !token.isEmpty {
                    cont.resume(returning: token)
                } else {
                    cont.resume(throwing: ClientError.underlying("AppCheck token vide."))
                }
            }
        }
    }

    // MARK: - HTTP

    private func postJSON(url: URL, idToken: String, appCheckToken: String, payload: [String: Any]) async throws -> RecognitionResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // ✅ Firebase Auth (ID token)
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")

        // ✅ Firebase App Check
        req.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")

        // (Optionnel) debug
        req.setValue("Collectly-iOS", forHTTPHeaderField: "X-Client")

        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ClientError.underlying("Réponse serveur invalide.")
        }

        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "—"
            throw ClientError.requestFailed(http.statusCode, body)
        }

        // Réponse JSON
        do {
            return try JSONDecoder().decode(RecognitionResponse.self, from: data)
        } catch {
            // utile pour débugger si le backend renvoie un autre format
            let raw = String(data: data, encoding: .utf8) ?? "—"
            throw ClientError.underlying("Décodage impossible. Réponse brute: \(raw)")
        }
    }
}
