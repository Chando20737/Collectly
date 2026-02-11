// update_players.swift
// Run (macOS terminal):
//   cd /Users/ericchandonnet/Documents/Collectly/Collectly
//   swift update_players.swift
//
// IMPORTANT: This file is safe to keep inside the Xcode project because it
// is excluded from iOS builds via the compilation condition below.

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

private extension String {
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private struct NameMerger {
    private var set: Set<String>

    init(existing: [String]) {
        self.set = Set(existing.map { $0.trimmed() }.filter { !$0.isEmpty })
    }

    mutating func add(_ name: String) {
        let n = name.trimmed()
        guard !n.isEmpty else { return }
        set.insert(n)
    }

    func sortedNames() -> [String] {
        set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - NHL fetcher (api-web.nhl.com)

private enum NHLRosterFetcher {

    // We keep a broad list; some may 404 depending on season availability.
    static let defaultSeasons: [String] = [
        "20252026", "20242025", "20232024", "20222023", "20212022",
        "20202021", "20192020", "20182019", "20172018", "20162017"
    ]

    static func fetchAllPlayerNames(seasons: [String]) async -> (names: [String], warnings: [String]) {
        // Current NHL team tri-codes. (If some change, the script will just warn.)
        let teams: [String] = [
            "ANA","ARI","BOS","BUF","CAR","CBJ","CGY","CHI","COL","DAL",
            "DET","EDM","FLA","LAK","MIN","MTL","NJD","NSH","NYI","NYR",
            "OTT","PHI","PIT","SJS","SEA","STL","TBL","TOR","VAN","VGK",
            "WPG","WSH"
        ]

        var all: [String] = []
        var warnings: [String] = []

        for season in seasons {
            for tri in teams {
                // Endpoint example:
                // https://api-web.nhl.com/v1/roster/MTL/20232024
                let urlString = "https://api-web.nhl.com/v1/roster/\(tri)/\(season)"
                guard let url = URL(string: urlString) else { continue }

                do {
                    let (data, resp) = try await URLSession.shared.data(from: url)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    guard (200...299).contains(status) else {
                        warnings.append("- \(tri) \(season): http(\(status))")
                        continue
                    }

                    // Parse JSON loosely
                    if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // Roster JSON includes keys like "forwards", "defensemen", "goalies" with arrays of player dicts.
                        for key in ["forwards", "defensemen", "goalies"] {
                            guard let arr = obj[key] as? [[String: Any]] else { continue }
                            for p in arr {
                                // API usually exposes "firstName"/"lastName" nested as { default: "" }
                                let first = (p["firstName"] as? [String: Any])?["default"] as? String
                                let last  = (p["lastName"] as? [String: Any])?["default"] as? String
                                if let f = first, let l = last {
                                    let full = "\(f) \(l)".trimmed()
                                    if !full.isEmpty { all.append(full) }
                                }
                            }
                        }
                    }
                } catch {
                    warnings.append("- \(tri) \(season): \(error.localizedDescription)")
                }
            }
        }

        // De-dupe
        let unique = Array(Set(all))
        return (unique, warnings)
    }
}

// MARK: - Main

@main
struct PlayerListMain {
    static func main() async {
        // Where to write: project folder by default (same folder as this script).
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let outURL = cwd.appendingPathComponent("players.txt")

        // Seasons to attempt
        let seasons = NHLRosterFetcher.defaultSeasons

        print("Will write: \(outURL.path)")
        print("Seasons: \(seasons.joined(separator: ", "))")

        // Load existing
        var existing: [String] = []
        if fm.fileExists(atPath: outURL.path), let txt = readTextFile(outURL) {
            existing = txt.split(separator: "\n").map { String($0).trimmed() }.filter { !$0.isEmpty }
            print("Existing names loaded: \(existing.count)")
        } else {
            print("No existing players.txt found; creating a new one.")
        }

        var merger = NameMerger(existing: existing)

        let (nhlNames, warnings) = await NHLRosterFetcher.fetchAllPlayerNames(seasons: seasons)
        print("NHL fetched: \(nhlNames.count)")
        nhlNames.forEach { merger.add($0) }

        let finalNames = merger.sortedNames()
        let finalText = finalNames.joined(separator: "\n") + "\n"

        do {
            try writeTextFile(finalText, to: outURL)
            print("\n✅ Wrote \(finalNames.count) unique names to players.txt")
        } catch {
            print("\n❌ Failed to write file: \(error)")
        }

        if !warnings.isEmpty {
            print("\n⚠️  Some fetches failed (not fatal):")
            warnings.prefix(80).forEach { print($0) }
            if warnings.count > 80 { print("... (\(warnings.count - 80) more)") }
        }

        print("\nDone.")
    }
}

#endif
