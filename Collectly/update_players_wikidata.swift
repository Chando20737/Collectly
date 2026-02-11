// update_players_wikidata.swift
//
// Run (macOS terminal):
//   cd /Users/ericchandonnet/Documents/Collectly/Collectly
//   swift update_players_wikidata.swift
//
// Merges:
//  1) Current rosters from NHL (api-web.nhl.com)
//  2) Historical NHL players from Wikidata (SPARQL)
// into players.txt (one name per line).
//
// Safe to keep in your Xcode project: excluded from iOS builds.

#if !os(iOS)

import Foundation

// MARK: - Helpers

private func readTextFile(_ url: URL) -> String? {
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        return nil
    }
}

private func writeTextFile(_ text: String, to url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func normalizeKey(_ s: String) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "" }

    // Remove diacritics + lowercase
    var t = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    t = t.lowercased()

    // Keep letters + spaces only
    let allowed = CharacterSet.letters.union(.whitespaces)
    t = t.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }.reduce("") { $0 + String($1) }

    // Collapse spaces
    t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return t
}

private func uniqueSortedDisplayNames(from dict: [String: String]) -> [String] {
    return dict.values
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

private func loadExistingNames(playersTxtURL: URL) -> [String: String] {
    guard let raw = readTextFile(playersTxtURL) else { return [:] }
    var map: [String: String] = [:]
    raw.split(whereSeparator: \.isNewline).forEach { line in
        let name = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return }
        let key = normalizeKey(name)
        if !key.isEmpty { map[key] = name }
    }
    return map
}

private func projectPlayersTxtURL() -> URL {
    // Writes next to this script when executed from the Collectly/Collectly folder.
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("players.txt")
}

// MARK: - NHL fetch

private struct NHLTeamsResponse: Decodable {
    struct Team: Decodable {
        let abbrev: String?
        let triCode: String?
        let name: Name?
        struct Name: Decodable { let defaultName: String?; let `default`: String? }

        enum CodingKeys: String, CodingKey {
            case abbrev
            case triCode
            case name
        }
    }
    let teams: [Team]
}

private func fetchNHLTeamAbbrevs() async throws -> [String] {
    let url = URL(string: "https://api-web.nhl.com/v1/teams")!
    var req = URLRequest(url: url)
    req.timeoutInterval = 30

    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
    guard code == 200 else {
        throw NSError(domain: "NHL", code: code, userInfo: [NSLocalizedDescriptionKey: "NHL teams endpoint HTTP \(code)"])
    }

    // The NHL endpoint schema is not always stable; decode defensively.
    if let decoded = try? JSONDecoder().decode(NHLTeamsResponse.self, from: data) {
        let abbr = decoded.teams.compactMap { $0.abbrev ?? $0.triCode }
        return Array(Set(abbr)).sorted()
    }

    // Fallback: best-effort parse
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let teams = obj?["teams"] as? [[String: Any]] ?? []
    var out: [String] = []
    for t in teams {
        if let a = t["abbrev"] as? String { out.append(a) }
        else if let a = t["triCode"] as? String { out.append(a) }
    }
    return Array(Set(out)).sorted()
}

private struct NHLRosterResponse: Decodable {
    struct RosterSpot: Decodable {
        struct Person: Decodable {
            let fullName: String?
            let firstName: String?
            let lastName: String?
            let defaultName: String?
        }
        let firstName: String?
        let lastName: String?
        let person: Person?
    }
    let forwards: [RosterSpot]?
    let defensemen: [RosterSpot]?
    let goalies: [RosterSpot]?
}

private func extractFullName(from spot: NHLRosterResponse.RosterSpot) -> String? {
    if let p = spot.person {
        if let n = p.fullName, !n.isEmpty { return n }
        if let dn = p.defaultName, !dn.isEmpty { return dn }
        if let f = p.firstName, let l = p.lastName { return "\(f) \(l)" }
    }
    if let f = spot.firstName, let l = spot.lastName { return "\(f) \(l)" }
    return nil
}

private func fetchRoster(teamAbbrev: String, season: String) async throws -> [String] {
    // Example: https://api-web.nhl.com/v1/roster/MTL/20242025
    let url = URL(string: "https://api-web.nhl.com/v1/roster/\(teamAbbrev)/\(season)")!
    var req = URLRequest(url: url)
    req.timeoutInterval = 30

    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
    guard code == 200 else {
        throw NSError(domain: "NHL", code: code, userInfo: [NSLocalizedDescriptionKey: "Roster \(teamAbbrev) \(season) HTTP \(code)"])
    }

    let decoded = try JSONDecoder().decode(NHLRosterResponse.self, from: data)
    let all = (decoded.forwards ?? []) + (decoded.defensemen ?? []) + (decoded.goalies ?? [])
    return all.compactMap(extractFullName(from:))
}

private func fetchCurrentRosters(seasons: [String]) async -> (names: [String], warnings: [String]) {
    var warnings: [String] = []
    var names: [String] = []

    do {
        let teams = try await fetchNHLTeamAbbrevs()
        for season in seasons {
            for team in teams {
                do {
                    let roster = try await fetchRoster(teamAbbrev: team, season: season)
                    names.append(contentsOf: roster)
                } catch {
                    // Not fatal (some seasons or teams may 404 depending on NHL API availability)
                    warnings.append("- \(team) \(season): \(error)")
                }
            }
        }
    } catch {
        warnings.append("- Teams fetch failed: \(error)")
    }

    return (names, warnings)
}

// MARK: - Wikidata fetch

private struct WikidataResult: Decodable {
    struct Results: Decodable {
        struct Binding: Decodable {
            struct Value: Decodable { let value: String }
            let playerLabel: Value
        }
        let bindings: [Binding]
    }
    let results: Results
}

private func wikidataQuery(limit: Int, offset: Int) -> String {
    // Idea: an NHL player is an ice hockey player (occupation) who has played
    // for a team whose league is the NHL.
    return """
    SELECT DISTINCT ?playerLabel WHERE {
      ?player wdt:P106 wd:Q11513337 .
      ?player p:P54 ?st .
      ?st ps:P54 ?team .
      ?team wdt:P118 wd:Q121589 .
      SERVICE wikibase:label { bd:serviceParam wikibase:language \"en\". }
    }
    LIMIT \(limit)
    OFFSET \(offset)
    """
}

private func fetchWikidataPlayers(maxPages: Int = 30, pageSize: Int = 2000) async throws -> [String] {
    var out: [String] = []
    var offset = 0

    for _ in 0..<maxPages {
        let q = wikidataQuery(limit: pageSize, offset: offset)
        var comps = URLComponents(string: "https://query.wikidata.org/sparql")!
        comps.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "query", value: q)
        ]

        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 60
        req.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        req.setValue("Collectly players updater (contact: eric)", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw NSError(domain: "Wikidata", code: code, userInfo: [NSLocalizedDescriptionKey: "Wikidata HTTP \(code)"])
        }

        let decoded = try JSONDecoder().decode(WikidataResult.self, from: data)
        let batch = decoded.results.bindings.map { $0.playerLabel.value }
        if batch.isEmpty { break }

        out.append(contentsOf: batch)
        offset += pageSize

        // Be a good citizen: small delay to reduce rate-limiting risk
        try await Task.sleep(nanoseconds: 250_000_000) // 0.25s
    }

    return out
}

// MARK: - Main

@main
struct UpdatePlayersWikidataMain {
    static func main() async {
        let playersURL = projectPlayersTxtURL()
        print("Will write: \(playersURL.path)")

        var nameMap = loadExistingNames(playersTxtURL: playersURL)
        print("Existing names loaded: \(nameMap.count)")

        // Current seasons (you can adjust/remove as you like)
        let seasons = ["20252026", "20242025", "20232024"]
        print("Seasons: \(seasons.joined(separator: ", "))")

        let nhl = await fetchCurrentRosters(seasons: seasons)
        print("NHL fetched: \(nhl.names.count)")

        // Wikidata
        var wikidataNames: [String] = []
        do {
            wikidataNames = try await fetchWikidataPlayers(maxPages: 30, pageSize: 2000)
            print("Wikidata fetched: \(wikidataNames.count)")
        } catch {
            print("⚠️ Wikidata fetch failed (not fatal): \(error)")
        }

        let combined = nhl.names + wikidataNames
        for n in combined {
            let key = normalizeKey(n)
            if key.isEmpty { continue }
            if nameMap[key] == nil {
                nameMap[key] = n.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let finalNames = uniqueSortedDisplayNames(from: nameMap)
        do {
            try writeTextFile(finalNames.joined(separator: "\n") + "\n", to: playersURL)
            print("✅ Wrote \(finalNames.count) unique names to players.txt")
        } catch {
            print("❌ Failed to write players.txt: \(error)")
            exit(1)
        }

        if !nhl.warnings.isEmpty {
            print("\n⚠️ NHL warnings (not fatal):")
            nhl.warnings.prefix(25).forEach { print($0) }
            if nhl.warnings.count > 25 {
                print("... (\(nhl.warnings.count - 25) more)")
            }
        }

        print("Done.")
    }
}

#endif
