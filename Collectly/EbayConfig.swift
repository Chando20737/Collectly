import Foundation

/// Centralized eBay configuration.
///
/// Reads values from the app's Info.plist so secrets aren't hardcoded.
///
/// Required Info.plist keys (String):
/// - EBAY_CLIENT_ID
/// - EBAY_CLIENT_SECRET
/// - EBAY_MARKETPLACE_ID   (ex: EBAY_CA)
///
/// Optional Info.plist key (String):
/// - EBAY_ENV              ("production" | "sandbox")  // default: production
enum EbayConfig {

    enum Environment: String {
        case production
        case sandbox

        static var current: Environment {
            let raw = (Bundle.main.object(forInfoDictionaryKey: "EBAY_ENV") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if raw == "sandbox" { return .sandbox }
            return .production
        }

        var apiBaseURL: URL {
            switch self {
            case .production: return URL(string: "https://api.ebay.com")!
            case .sandbox: return URL(string: "https://api.sandbox.ebay.com")!
            }
        }
    }

    static var environment: Environment { .current }

    // MARK: - Credentials (Info.plist)

    static var clientId: String { requiredString("EBAY_CLIENT_ID") }
    static var clientSecret: String { requiredString("EBAY_CLIENT_SECRET") }
    static var marketplaceId: String { requiredString("EBAY_MARKETPLACE_ID") }

    // MARK: - Endpoints / scopes

    /// OAuth endpoint for client_credentials flow.
    static var oauthTokenURL: URL {
        environment.apiBaseURL.appendingPathComponent("identity/v1/oauth2/token")
    }

    /// App-level scope for Browse (guest) use-cases.
    ///
    /// This scope is commonly used for Browse API + other "guest" buy APIs.
    /// Add more scopes later if you expand into other APIs.
    static var appScope: String {
        "https://api.ebay.com/oauth/api_scope"
    }

    // MARK: - Helpers

    private static func requiredString(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
