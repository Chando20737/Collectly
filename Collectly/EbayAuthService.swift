//
//  EbayAuthService.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation

final class EbayAuthService {
    struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String
        let expires_in: Int
    }

    private var cachedToken: String?
    private var tokenExpiry: Date?

    func getAppToken() async throws -> String {
        if let cachedToken,
           let tokenExpiry,
           tokenExpiry > Date().addingTimeInterval(60) {
            return cachedToken
        }

        let url = URL(string: "https://api.ebay.com/identity/v1/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Basic Auth = base64(clientId:clientSecret)
        let creds = "\(EbayConfig.clientId):\(EbayConfig.clientSecret)"
        let credsB64 = Data(creds.utf8).base64EncodedString()
        request.setValue("Basic \(credsB64)", forHTTPHeaderField: "Authorization")

        // client_credentials pour Browse API (scope “buy.browse”)
        let body = "grant_type=client_credentials&scope=https%3A%2F%2Fapi.ebay.com%2Foauth%2Fapi_scope%2Fbuy.browse"
        request.httpBody = Data(body.utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)

        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "EbayAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Token eBay refusé: \(text)"])
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        cachedToken = decoded.access_token
        tokenExpiry = Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        return decoded.access_token
    }
}

