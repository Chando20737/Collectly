import Foundation

/// Fetches an **app** access token using eBay OAuth (client_credentials).
///
/// Use this token for eBay Buy APIs such as **Browse API** when you don't need user consent.
final class EbayAuthService {

    static let shared = EbayAuthService()

    private let session: URLSession

    // Simple in-memory cache (token typically lasts ~2 hours)
    private var cachedToken: String?
    private var cachedTokenExpiry: Date?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Legacy name used elsewhere in the project.
    /// Returns a valid app access token (cached when possible).
    func getAppToken() async throws -> String {
        return try await getAppAccessToken()
    }

    /// Returns a valid app access token (cached when possible).
    func getAppAccessToken() async throws -> String {
        if let token = cachedToken,
           let expiry = cachedTokenExpiry,
           expiry.timeIntervalSinceNow > 60 { // keep 60s safety buffer
            return token
        }

        let clientId = EbayConfig.clientId
        let clientSecret = EbayConfig.clientSecret

        var request = URLRequest(url: EbayConfig.oauthTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic \(Self.basicAuthHeader(clientId: clientId, clientSecret: clientSecret))",
                         forHTTPHeaderField: "Authorization")

        let scope = EbayConfig.appScope
        let body = "grant_type=client_credentials&scope=\(Self.formURLEncode(scope))"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw EbayAuthError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            // Try to surface OAuth error payload (invalid_client, etc.)
            let payload = String(data: data, encoding: .utf8) ?? ""
            throw EbayAuthError.httpError(status: http.statusCode, body: payload)
        }

        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)

        cachedToken = decoded.access_token
        cachedTokenExpiry = Date().addingTimeInterval(TimeInterval(decoded.expires_in))

        return decoded.access_token
    }
}

// MARK: - Models

private struct OAuthTokenResponse: Decodable {
    let access_token: String
    let token_type: String?
    let expires_in: Int
}

// MARK: - Errors

enum EbayAuthError: LocalizedError {
    case invalidResponse
    case httpError(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from eBay OAuth endpoint."
        case let .httpError(status, body):
            if body.isEmpty {
                return "eBay OAuth HTTP \(status)."
            }
            return "eBay OAuth HTTP \(status): \(body)"
        }
    }
}

// MARK: - Helpers

private extension EbayAuthService {

    static func basicAuthHeader(clientId: String, clientSecret: String) -> String {
        let raw = "\(clientId):\(clientSecret)"
        let data = Data(raw.utf8)
        return data.base64EncodedString()
    }

    /// Encodes a string for x-www-form-urlencoded query parameter usage.
    /// (We keep it simple: percent-encode using urlQueryAllowed minus some reserved characters.)
    static func formURLEncode(_ string: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        // RFC 3986 reserved characters that should be percent-encoded in query values
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
