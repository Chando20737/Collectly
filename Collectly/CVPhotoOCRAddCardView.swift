import SwiftUI
import SwiftData
import UIKit
import Foundation
@preconcurrency import Vision
import AVFoundation
import CoreImage
import FirebaseStorage
import FirebaseFirestore

// MARK: Player Name Normalization
fileprivate func normalizePlayerNameDisplay(_ name: String) -> String {
    let cleaned = name
        .lowercased()
        .split(separator: " ")
        .map { $0.capitalized }
        .joined(separator: " ")
    return cleaned
}

// MARK: Cyrillic filtering
/// Returns true if the string contains Cyrillic characters.
/// In our use-case (sports cards), this is almost always OCR garbage and should be ignored.
fileprivate func containsCyrillic(_ s: String) -> Bool {
    for scalar in s.unicodeScalars {
        switch scalar.value {
        // Cyrillic
        case 0x0400...0x04FF,
             0x0500...0x052F,
             0x2DE0...0x2DFF,
             0xA640...0xA69F:
            return true
        default:
            continue
        }
    }
    return false
}

// MARK: ASCII/Latin filtering
/// Returns true if the string contains only ASCII characters OR Latin script characters.
/// This helps reject OCR garbage (ex: Cyrillic/Greek/etc.) while still allowing names with accents.
fileprivate func isAsciiOrLatinOnly(_ s: String) -> Bool {
    // Allowed punctuation we commonly see in names.
    let allowedAscii: Set<UInt32> = [
        0x20, // space
        0x27, // '
        0x2D, // -
        0x2019 // â€™
    ]

    for scalar in s.unicodeScalars {
        let v = scalar.value

        // ASCII letters/digits/spaces/punct
        if v <= 0x7F {
            if CharacterSet.alphanumerics.contains(scalar) { continue }
            if allowedAscii.contains(v) { continue }
            // Other ASCII punctuation is not useful for names.
            return false
        }

        // Combining diacritics (allow)
        if (0x0300...0x036F).contains(v) { continue }

        // Latin-1 Supplement + Latin Extended blocks + Latin Extended Additional
        if (0x00C0...0x024F).contains(v) { continue }
        if (0x1E00...0x1EFF).contains(v) { continue }

        // Everything else: reject (Cyrillic/Greek/etc.)
        return false
    }
    return true
}

// MARK: - Array helpers
fileprivate extension Array where Element: Hashable {
    /// Intersection preserving no guaranteed order (returns unique elements).
    func intersection(_ other: [Element]) -> [Element] {
        Array(Set(self).intersection(Set(other)))
    }
}


// MARK: - Local Database Search

/// Formate le nom d'un set pour l'affichage
/// Enlève l'année et "Upper Deck" (car déjà dans "Compagnie")
fileprivate func formatSetName(_ fullName: String) -> String {
    var formatted = fullName
    
    // Enlever l'année au début (ex: "2025-26 ", "2024-25 ")
    // Pattern: YYYY-YY au début suivi d'un espace
    if let regex = try? NSRegularExpression(pattern: "^\\d{4}-\\d{2}\\s+", options: []) {
        let range = NSRange(formatted.startIndex..., in: formatted)
        formatted = regex.stringByReplacingMatches(in: formatted, range: range, withTemplate: "")
    }
    
    // Enlever "Upper Deck" complètement (déjà dans "Compagnie")
    formatted = formatted.replacingOccurrences(of: "Upper Deck ", with: "", options: .caseInsensitive)
    formatted = formatted.replacingOccurrences(of: "Upper Deck", with: "", options: .caseInsensitive)
    
    return formatted.trimmingCharacters(in: .whitespaces)
}

/// Normalise les années pour les saisons NHL (toujours format YYYY-YY)
/// Exemples: "2024" → "2024-25", "2023" → "2023-24", "2024-25" → "2024-25"
fileprivate func normalizeYear(_ year: String) -> String {
    let trimmed = year.trimmingCharacters(in: .whitespaces)
    
    // Si déjà au format YYYY-YY, retourner tel quel
    if let regex = try? NSRegularExpression(pattern: "^\\d{4}-\\d{2}$", options: []),
       regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
        return trimmed
    }
    
    // Si format YYYY (ex: "2024"), convertir en YYYY-YY (ex: "2024-25")
    if let regex = try? NSRegularExpression(pattern: "^(\\d{4})$", options: []),
       let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
       let yearRange = Range(match.range(at: 1), in: trimmed) {
        let yearStr = String(trimmed[yearRange])
        if let yearInt = Int(yearStr) {
            let nextYear = yearInt + 1
            let nextYearShort = String(nextYear).suffix(2)
            return "\(yearInt)-\(nextYearShort)"
        }
    }
    
    // Sinon retourner tel quel
    return trimmed
}

/// Cherche une carte dans tcdb_sets.json par joueur + set + année
/// Retourne le numéro de carte et le nom complet du set si trouvé
fileprivate func findCardInLocalDatabase(
    playerName: String,
    setName: String?,
    year: String?,
    detectedCardNumber: String? = nil
) -> (number: String?, fullSetName: String?)? {
    
    // Charger tcdb_sets.json
    guard let url = Bundle.main.url(forResource: "tcdb_sets", withExtension: "json") else {
        print("⚠️ tcdb_sets.json not found in bundle")
        return nil
    }
    
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sets = json["sets"] as? [String: [String: Any]] else {
        print("⚠️ Failed to load or parse tcdb_sets.json")
        return nil
    }
    
    // Normaliser le nom du joueur
    let normalizedPlayer = playerName.lowercased().trimmingCharacters(in: .whitespaces)
    
    print("🔍 Searching local database for player: [\(playerName)], set: [\(setName ?? "nil")], year: [\(year ?? "nil")]\(detectedCardNumber != nil ? ", detectedNumber: [\(detectedCardNumber!)]" : "")")
    
    // Collecter TOUTES les correspondances possibles
    var matches: [(setFullName: String, cardNumber: String, score: Int)] = []
    
    // Chercher dans chaque set
    for (setFullName, setData) in sets {
        var yearMismatchPenalty = 0  // Pénalité pour année non-exacte
        
        // Vérifier l'année si fournie (extraire l'année du nom du set)
        if let year = year, !year.isEmpty {
            // Chercher l'année dans le nom du set (ex: "2024-25 Upper Deck")
            let yearPattern = year.prefix(4)
            let yearNum = Int(yearPattern) ?? 0
            
            // ⚠️ TOLÉRANCE ±1 an: L'année doit correspondre exactement OU différer de max 1 an
            // Ex: si OCR dit "2024-25", accepter aussi "2025-26" (erreur OCR commune)
            let hasExactYearMatch = setFullName.contains(year) || 
                                   setFullName.hasPrefix(String(yearPattern)) ||
                                   setFullName.contains("\(yearPattern)-")
            
            // Si pas de match exact, vérifier ±1 an
            var hasToleranceMatch = false
            if !hasExactYearMatch && yearNum > 0 {
                let prevYear = yearNum - 1
                let nextYear = yearNum + 1
                hasToleranceMatch = setFullName.contains("\(prevYear)-") || 
                                   setFullName.contains("\(nextYear)-") ||
                                   setFullName.hasPrefix(String(prevYear)) ||
                                   setFullName.hasPrefix(String(nextYear))
            }
            
            if !hasExactYearMatch && !hasToleranceMatch {
                continue
            }
            
            // 🎯 IMPORTANT: Si l'année ne match pas exactement, pénaliser LOURDEMENT le score
            // Ceci empêche 2024-25 de scorer plus haut que 2025-26 quand "2025-26" est clairement détecté
            yearMismatchPenalty = hasExactYearMatch ? 0 : -1000
        }
        
        // Vérifier le set si fourni
        var hasMatchingWord = true
        if let setName = setName, !setName.isEmpty {
            let normalizedSetName = setName.lowercased()
            let normalizedFullName = setFullName.lowercased()
            
            // 🎯 LOGIQUE SPÉCIALE: Si le set détecté est "Series 1" ou "Series 2" uniquement,
            // prioriser le set de base "Upper Deck" (pas Artifacts, Allure, etc.)
            let isSeriesOnly = normalizedSetName.contains("series 1") || normalizedSetName.contains("series 2") ||
                               normalizedSetName == "series 1" || normalizedSetName == "series 2" ||
                               normalizedSetName == "2025-26 series 1" || normalizedSetName == "2025-26 series 2" ||
                               normalizedSetName == "2024-25 series 1" || normalizedSetName == "2024-25 series 2"
            let hasOtherKeywords = normalizedSetName.contains("young guns") || normalizedSetName.contains("artifacts") ||
                                   normalizedSetName.contains("allure") || normalizedSetName.contains("mvp") ||
                                   normalizedSetName.contains("outburst") || normalizedSetName.contains("portraits")
            
            if isSeriesOnly && !hasOtherKeywords {
                // Pour "Series 1/2" seul, SEULEMENT matcher le set de base Upper Deck
                let isBaseSet = normalizedFullName.hasSuffix("upper deck") || 
                               (normalizedFullName.contains("upper deck") && 
                                !normalizedFullName.contains("artifacts") &&
                                !normalizedFullName.contains("allure") &&
                                !normalizedFullName.contains("mvp") &&
                                !normalizedFullName.contains("young guns") &&
                                !normalizedFullName.contains("portraits") &&
                                !normalizedFullName.contains("outburst"))
                if !isBaseSet {
                    continue  // Skip les autres sets
                }
            } else {
                // Mots à ignorer (parallels, inserts, variants, noms d'équipes, et mots génériques)
                let parallelKeywords = ["outburst", "exclusives", "acetate", "clear", "cut", "foil", 
                                       "rainbow", "auto", "autograph", "patch", "jersey", "relic",
                                       "black", "blue", "green", "red", "gold", "silver", "purple",
                                       "dazzlers", "portrait", "speckle", "canvas", "high", "gloss",
                                       "series", "1", "2", "base", "rookie", "sizzle", "reel",
                                       "script", "gold script", "silver script", "retro", "vintage",
                                       "colors", "contours", "laser", "focused", "net", "presence",
                                       "rising", "occasion", "mascot", "battle", "stickers",
                                       // Noms d'équipes NHL (souvent détectés par OCR sur le dos des cartes)
                                       "rangers", "rangerso", "leafs", "canadiens", "bruins", "penguins",
                                       "blackhawks", "oilers", "flames", "canucks", "jets", "senators",
                                       "lightning", "panthers", "capitals", "hurricanes", "devils",
                                       "islanders", "flyers", "blue jackets", "predators", "blues",
                                       "wild", "avalanche", "stars", "ducks", "kings", "sharks",
                                       "golden knights", "kraken", "coyotes", "maple", "york", "new",
                                       "los", "angeles", "san", "jose", "tampa", "bay", "vegas"]
                
                // Filtrer les mots de parallels du setName
                let setNameWords = normalizedSetName.split(separator: " ").filter { word in
                    !parallelKeywords.contains(String(word))
                }
                
                // Si après filtrage il reste des mots, au moins un doit matcher
                if !setNameWords.isEmpty {
                    hasMatchingWord = setNameWords.contains { word in
                        normalizedFullName.contains(word)
                    }
                    
                    if !hasMatchingWord {
                        continue
                    }
                }
            }
            // Si tous les mots étaient des parallels, on accepte le set
        }
        
        // Obtenir les cartes du set
        guard let cards = setData["cards"] as? [String: String] else {
            continue
        }
        
        // Chercher le joueur dans les cartes
        for (cardNumber, cardPlayer) in cards {
            let normalizedCardPlayer = cardPlayer.lowercased().trimmingCharacters(in: .whitespaces)
            
            // Correspondance exacte du nom
            var isMatch = normalizedCardPlayer == normalizedPlayer
            
            // 🔍 FALLBACK: Correspondance partielle pour noms composés
            // Ex: "Olivier Groulx" devrait matcher "Benoit Olivier Groulx"
            if !isMatch {
                let playerWords = normalizedPlayer.split(separator: " ")
                let cardPlayerWords = normalizedCardPlayer.split(separator: " ")
                
                // Si le nom recherché a 2+ mots ET est contenu dans le nom de la carte
                if playerWords.count >= 2 {
                    // Vérifier que TOUS les mots du nom recherché sont dans le nom de la carte
                    let allWordsMatch = playerWords.allSatisfy { word in
                        cardPlayerWords.contains(word)
                    }
                    
                    // Vérifier aussi que le dernier mot (nom de famille) correspond
                    let lastNameMatches = playerWords.last == cardPlayerWords.last
                    
                    if allWordsMatch && lastNameMatches {
                        isMatch = true
                        print("   ℹ️ Partial match: [\(playerName)] → [\(cardPlayer)]")
                    }
                }
            }
            
            if isMatch {
                // Calculer un score pour ce set
                var score = 100  // Score de base
                
                if let setName = setName, !setName.isEmpty {
                    let normalizedSetName = setName.lowercased()
                    let normalizedFullName = setFullName.lowercased()
                    
                    // Compter les mots en commun
                    let setNameWords = Set(normalizedSetName.split(separator: " "))
                    let fullNameWords = Set(normalizedFullName.split(separator: " "))
                    let commonWords = setNameWords.intersection(fullNameWords)
                    
                    // Bonus pour chaque mot en commun
                    score += commonWords.count * 30
                    
                    // Bonus pour correspondance exacte des mots (sans préfixes/suffixes)
                    let exactMatches = setNameWords.filter { fullNameWords.contains($0) }
                    score += exactMatches.count * 20
                    
                    // Pénalité pour les mots supplémentaires (variantes)
                    let extraWords = fullNameWords.subtracting(setNameWords)
                    
                    // Mots de variantes qui réduisent le score
                    let variantKeywords = ["auto", "material", "acetate", "limited", "mystery", "black", "blue", "green", "red", "gold", "silver", "inscribed"]
                    let hasVariantWords = extraWords.contains { word in
                        variantKeywords.contains(String(word))
                    }
                    
                    if hasVariantWords {
                        score -= 50  // Grosse pénalité pour les variantes
                    }
                    
                    // Bonus pour les sets plus simples (moins de mots)
                    let wordCountDiff = fullNameWords.count - setNameWords.count
                    score -= wordCountDiff * 10
                    
                    // Bonus supplémentaire si le set name fourni est contenu tel quel dans le nom complet
                    if normalizedFullName.contains(normalizedSetName) {
                        score += 50
                    }
                    
                    // 🎯 BONUS SPÉCIAUX: Pour les subsets très spécifiques, donner priorité absolue
                    // Ces subsets doivent gagner sur les base sets (Series 1, Series 2)
                    let specificSubsets = ["portraits", "dazzlers", "future watch", "young guns", "exclusives", 
                                         "canvas", "clear cut", "high gloss", "population count", "sizzle reel"]
                    
                    let setNameHasSubset = specificSubsets.contains { subset in
                        normalizedSetName.contains(subset)
                    }
                    
                    let fullNameHasSubset = specificSubsets.contains { subset in
                        normalizedFullName.contains(subset)
                    }
                    
                    // Si le setName demandé contient un subset spécifique ET le fullName aussi, gros bonus
                    if setNameHasSubset && fullNameHasSubset {
                        // Vérifier que c'est le MÊME subset
                        for subset in specificSubsets {
                            if normalizedSetName.contains(subset) && normalizedFullName.contains(subset) {
                                score += 200  // Priorité absolue!
                                print("   🎯 Exact subset match: [\(subset)] - score boosted to \(score)")
                                break
                            }
                        }
                    }
                    
                    // Pénalité si le setName demande un subset mais le fullName n'en a pas
                    if setNameHasSubset && !fullNameHasSubset {
                        score -= 100  // Grosse pénalité
                    }
                    
                    // Pénalité si le fullName a "Series" mais le setName ne le demande pas
                    if normalizedFullName.contains("series") && !normalizedSetName.contains("series") {
                        score -= 30  // Éviter les base sets quand un subset est demandé
                    }
                }
                
                // 🎯 BONUS YOUNG GUNS: Si le card number est dans les ranges Young Guns,
                // booster le score des sets "Young Guns"
                let isYoungGunsSet = setFullName.lowercased().contains("young guns")
                
                if let cardNum = Int(cardNumber.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)) {
                    let isYoungGunsRange = (201...250).contains(cardNum) || (451...500).contains(cardNum) || (701...730).contains(cardNum)
                    
                    if isYoungGunsRange && isYoungGunsSet {
                        score += 500  // Gros bonus pour Young Guns dans la bonne range
                        print("   🎯 Young Guns range match: card #\(cardNum) is in YG range - score boosted to \(score)")
                    } else if isYoungGunsRange && !isYoungGunsSet {
                        // Pénalité pour les non-Young Guns quand le numéro est dans la range YG
                        score -= 200
                    } else if !isYoungGunsRange && isYoungGunsSet {
                        // Pénalité pour Young Guns quand le numéro N'EST PAS dans la range
                        score -= 300
                    }
                } else {
                    // ⚠️ AUCUN numéro détecté : donner un léger avantage à Young Guns
                    // car c'est le subset le plus commun pour les rookies
                    if isYoungGunsSet && (detectedCardNumber == nil || detectedCardNumber?.isEmpty == true) {
                        score += 50  // Petit bonus par défaut
                        print("   ℹ️ No card number detected, giving slight bonus to Young Guns")
                    }
                }
                
                // 🎯 BONUS MASSIF: Si le numéro de cette carte correspond au numéro détecté
                // Ce bonus doit avoir la PRIORITÉ ABSOLUE sur tout le reste
                if let detectedCardNumber = detectedCardNumber, !detectedCardNumber.isEmpty {
                    let normalizedDetected = detectedCardNumber.uppercased()
                        .replacingOccurrences(of: "#", with: "")
                        .replacingOccurrences(of: " ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    let normalizedCard = cardNumber.uppercased()
                        .replacingOccurrences(of: "#", with: "")
                        .replacingOccurrences(of: " ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    
                    if normalizedCard == normalizedDetected {
                        score += 1000  // PRIORITÉ ABSOLUE!
                        print("   🎯🎯🎯 DETECTED NUMBER MATCH: [\(cardNumber)] matches detected [\(detectedCardNumber)] - score boosted to \(score)")
                    }
                }
                
                // Appliquer la pénalité d'année
                score += yearMismatchPenalty
                
                matches.append((setFullName: setFullName, cardNumber: cardNumber, score: score))
            }
        }
    }
    
    // Si on a trouvé des correspondances
    if !matches.isEmpty {
        // Trier par score décroissant
        matches.sort { $0.score > $1.score }
        
        // Afficher les candidats
        if matches.count > 1 {
            print("🎯 Found \(matches.count) matches for [\(playerName)], selecting best:")
            for (i, match) in matches.prefix(5).enumerated() {
                print("   \(i+1). [\(match.setFullName)] score=\(match.score)")
            }
        }
        
        // Retourner le meilleur match
        let bestMatch = matches[0]
        let formattedSetName = formatSetName(bestMatch.setFullName)
        print("✅ Found in local database: player=[\(playerName)], number=[\(bestMatch.cardNumber)], set=[\(bestMatch.setFullName)] → formatted: [\(formattedSetName)]")
        return (number: bestMatch.cardNumber, fullSetName: formattedSetName)
    }
    
    print("❌ Player [\(playerName)] not found in local database")
    return nil
}

/// Extrait un numéro de carte court depuis les lignes OCR de l'arrière
/// Préfère les numéros courts (1-3 chiffres) qui sont généralement le vrai numéro
/// Ignore les print runs (/XXX) et les années
/// Extrait tous les numéros de carte possibles depuis les lignes OCR de l'arrière
/// Retourne une liste triée par score (meilleurs en premier)
fileprivate func extractCardNumberFromOCR(_ lines: [String]) -> [(number: String, score: Int)] {
    var candidates: [(number: String, score: Int)] = []
    
    for (index, line) in lines.prefix(20).enumerated() {  // Regarder les 20 premières lignes
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        
        // Bonus pour les lignes en haut (le numéro est souvent visible en premier)
        let positionBonus = max(0, 20 - index)
        
        // Pattern 1: Juste un nombre court seul sur une ligne (ex: "116")
        if let regex = try? NSRegularExpression(pattern: "^\\s*(\\d{1,3})\\s*$", options: []) {
            if let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let numRange = Range(match.range(at: 1), in: trimmed) {
                let num = String(trimmed[numRange])
                
                // Ignorer les années (19XX, 20XX)
                if let intNum = Int(num), intNum < 1000 && intNum > 0 {
                    let score = 100 + positionBonus
                    candidates.append((number: num, score: score))
                    print("🔍 OCR candidate: [\(num)] score=\(score) from line [\(trimmed)]")
                }
            }
        }
        
        // Pattern 2: Préfixe + nombre (ex: "FW-116", "p-14", "#SR-19", "SR19")
        if let regex = try? NSRegularExpression(pattern: "([A-Za-z]{1,3})[-#\\s]?(\\d{1,3})", options: []) {
            let matches = regex.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
            for match in matches {
                if let prefixRange = Range(match.range(at: 1), in: trimmed),
                   let numRange = Range(match.range(at: 2), in: trimmed) {
                    let prefix = String(trimmed[prefixRange]).uppercased()  // Toujours en majuscules
                    let num = String(trimmed[numRange])
                    
                    // Ignorer si c'est une année ou trop grand
                    if let intNum = Int(num), intNum < 1000 && intNum > 0 {
                        // 🚫 BLACKLIST: Ignorer les préfixes qui sont des noms d'équipes ou mots communs
                        let teamNames = ["WILD", "RANGERS", "BRUINS", "LEAFS", "OILERS", "FLAMES", 
                                        "CANADIENS", "JETS", "CANUCKS", "AVALANCHE", "GOLDEN", "DEVILS",
                                        "ISLANDERS", "BLUES", "KINGS", "DUCKS", "SHARKS", "SENATORS",
                                        "SABRES", "RED", "BLUE", "BLACK", "WHITE", "GOLD", "SILVER",
                                        "UDC", "THE", "HIS", "WAS", "HAD", "HAS", "FOR", "AND", "BUT",
                                        "ARE", "WON", "LED", "NHL", "MVP", "ALL"]  // Mots communs anglais
                        
                        if teamNames.contains(prefix) {
                            print("🚫 Ignoring invalid prefix: [\(prefix)-\(num)]")
                            continue  // Skip ce candidat
                        }
                        
                        // Bonus pour préfixes connus
                        var score = 80 + positionBonus
                        if prefix == "FW" { score += 15 }  // Future Watch
                        if prefix == "YG" { score += 15 }  // Young Guns
                        if prefix == "PC" { score += 15 }  // Population Count
                        if prefix == "SR" { score += 15 }  // Sizzle Reel
                        if prefix == "P" { score += 15 }   // Portraits
                        if prefix == "E" { score += 10 }   // Exclusives
                        if prefix == "DZ" { score += 10 }  // Dazzlers
                        
                        // Garder le préfixe complet pour les subsets (SR-19, PC-4, etc.)
                        let fullNumber = "\(prefix)-\(num)"
                        candidates.append((number: fullNumber, score: score))
                        print("🔍 OCR candidate: [\(fullNumber)] score=\(score) from line [\(trimmed)]")
                        
                        // Aussi ajouter juste le numéro sans préfixe (pour compatibilité)
                        candidates.append((number: num, score: score - 5))
                        print("🔍 OCR candidate: [\(num)] (without prefix) score=\(score - 5) from line [\(trimmed)]")
                    }
                }
            }
        }
        
        // Pattern 3: "#123" seul
        if let regex = try? NSRegularExpression(pattern: "#(\\d{1,3})(?![/\\d])", options: []) {
            let matches = regex.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
            for match in matches {
                if let numRange = Range(match.range(at: 1), in: trimmed) {
                    let num = String(trimmed[numRange])
                    if let intNum = Int(num), intNum < 1000 && intNum > 0 {
                        let score = 90 + positionBonus
                        candidates.append((number: num, score: score))
                        print("🔍 OCR candidate: [\(num)] score=\(score) from line [\(trimmed)]")
                    }
                }
            }
        }
    }
    
    // Trier par score décroissant et retourner tous les candidats uniques
    let uniqueCandidates = Dictionary(grouping: candidates, by: { $0.number })
        .map { (number, group) in (number: number, score: group.map { $0.score }.max() ?? 0) }
        .sorted { $0.score > $1.score }
    
    if !uniqueCandidates.isEmpty {
        print("✅ Found \(uniqueCandidates.count) card number candidates from OCR (sorted by score)")
        for (i, candidate) in uniqueCandidates.prefix(5).enumerated() {
            print("   \(i+1). [\(candidate.number)] (score: \(candidate.score))")
        }
    } else {
        print("❌ No card number found in OCR")
    }
    
    return uniqueCandidates
}

/// Cherche une carte dans tcdb_sets.json par NUMÉRO de carte
/// Utile quand le nom du joueur est invalide (ex: "Watch Horizontal")
/// Retourne le nom du joueur, le nom complet du set et le brand si trouvé
fileprivate func findCardByNumber(
    cardNumber: String,
    setName: String?,
    year: String?,
    playerName: String? = nil
) -> (player: String?, fullSetName: String?, brand: String?)? {
    
    // Charger tcdb_sets.json
    guard let url = Bundle.main.url(forResource: "tcdb_sets", withExtension: "json") else {
        print("⚠️ tcdb_sets.json not found in bundle")
        return nil
    }
    
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sets = json["sets"] as? [String: [String: Any]] else {
        print("⚠️ Failed to load or parse tcdb_sets.json")
        return nil
    }
    
    // Normaliser le numéro (enlever #, espaces, mettre en majuscules)
    let normalizedNumber = cardNumber.uppercased()
        .replacingOccurrences(of: "#", with: "")
        .replacingOccurrences(of: " ", with: "")
        .trimmingCharacters(in: .whitespaces)
    
    print("🔍 Searching by number: [\(normalizedNumber)], set: [\(setName ?? "nil")], year: [\(year ?? "nil")]")
    
    // Fonction helper pour chercher avec une année spécifique
    func searchWithYear(_ searchYear: String?, exactOnly: Bool = false) -> (player: String?, fullSetName: String?, brand: String?)? {
        // Chercher dans chaque set
        for (setFullName, setData) in sets {
            // Vérifier l'année si fournie
            if let year = searchYear, !year.isEmpty {
                let yearPattern = year.prefix(4)
                
                // Match exact d'année
                let yearNum = Int(yearPattern) ?? 0
                let hasExactYearMatch = setFullName.contains(year) || 
                                       setFullName.hasPrefix(String(yearPattern)) ||
                                       setFullName.contains("\(yearPattern)-")
                
                // Si mode exact uniquement, skip si pas de match exact
                if exactOnly && !hasExactYearMatch {
                    continue
                }
                
                // Si pas mode exact, vérifier tolérance ±1 an
                var hasToleranceMatch = false
                if !exactOnly && !hasExactYearMatch && yearNum > 0 {
                    let prevYear = yearNum - 1
                    let nextYear = yearNum + 1
                    hasToleranceMatch = setFullName.contains("\(prevYear)-") || 
                                       setFullName.contains("\(nextYear)-") ||
                                       setFullName.hasPrefix(String(prevYear)) ||
                                       setFullName.hasPrefix(String(nextYear))
                }
                
                if !hasExactYearMatch && !hasToleranceMatch {
                    continue
                }
            }
            
            // Vérifier le set si fourni
            if let setName = setName, !setName.isEmpty {
                let normalizedSetName = setName.lowercased()
                let normalizedFullName = setFullName.lowercased()
                
                // 🎯 LOGIQUE SPÉCIALE: Si le set détecté est "Series 1" ou "Series 2" uniquement,
                // prioriser le set de base "Upper Deck" (pas Artifacts, Allure, etc.)
                let isSeriesOnly = normalizedSetName.contains("series 1") || normalizedSetName.contains("series 2") ||
                                   normalizedSetName == "series 1" || normalizedSetName == "series 2" ||
                                   normalizedSetName == "2025-26 series 1" || normalizedSetName == "2025-26 series 2" ||
                                   normalizedSetName == "2024-25 series 1" || normalizedSetName == "2024-25 series 2"
                let hasOtherKeywords = normalizedSetName.contains("young guns") || normalizedSetName.contains("artifacts") ||
                                       normalizedSetName.contains("allure") || normalizedSetName.contains("mvp") ||
                                       normalizedSetName.contains("outburst") || normalizedSetName.contains("portraits")
                
                if isSeriesOnly && !hasOtherKeywords {
                    // Pour "Series 1/2" seul, SEULEMENT matcher le set de base Upper Deck
                    // Le set de base s'appelle "2025-26 Upper Deck" ou "2024-25 Upper Deck" (sans "Series")
                    let isBaseSet = normalizedFullName.hasSuffix("upper deck") || 
                                   (normalizedFullName.contains("upper deck") && 
                                    !normalizedFullName.contains("artifacts") &&
                                    !normalizedFullName.contains("allure") &&
                                    !normalizedFullName.contains("mvp") &&
                                    !normalizedFullName.contains("young guns") &&
                                    !normalizedFullName.contains("portraits") &&
                                    !normalizedFullName.contains("outburst"))
                    if !isBaseSet {
                        continue  // Skip les autres sets
                    }
                } else {
                    // Mots à ignorer (parallels, inserts, variants, noms d'équipes, et mots génériques)
                    let parallelKeywords = ["outburst", "exclusives", "acetate", "clear", "cut", "foil", 
                                           "rainbow", "auto", "autograph", "patch", "jersey", "relic",
                                           "black", "blue", "green", "red", "gold", "silver", "purple",
                                           "dazzlers", "portrait", "speckle", "canvas", "high", "gloss",
                                           "series", "1", "2", "base", "rookie", "sizzle", "reel",
                                           "script", "gold script", "silver script", "retro", "vintage",
                                           "colors", "contours", "laser", "focused", "net", "presence",
                                           "rising", "occasion", "mascot", "battle", "stickers",
                                           // Noms d'équipes NHL (souvent détectés par OCR sur le dos des cartes)
                                           "rangers", "rangerso", "leafs", "canadiens", "bruins", "penguins",
                                           "blackhawks", "oilers", "flames", "canucks", "jets", "senators",
                                           "lightning", "panthers", "capitals", "hurricanes", "devils",
                                           "islanders", "flyers", "blue jackets", "predators", "blues",
                                           "wild", "avalanche", "stars", "ducks", "kings", "sharks",
                                           "golden knights", "kraken", "coyotes", "maple", "york", "new",
                                           "los", "angeles", "san", "jose", "tampa", "bay", "vegas"]
                    
                    // Filtrer les mots de parallels
                    let setNameWords = normalizedSetName.split(separator: " ").filter { word in
                        !parallelKeywords.contains(String(word))
                    }
                    
                    // Si après filtrage il reste des mots, au moins un doit matcher
                    if !setNameWords.isEmpty {
                        let hasMatchingWord = setNameWords.contains { word in
                            normalizedFullName.contains(word)
                        }
                        
                        if !hasMatchingWord {
                            continue
                        }
                    }
                }
            }
            
            // Obtenir les cartes du set
            guard let cards = setData["cards"] as? [String: String] else {
                continue
            }
            
            // Obtenir le brand du set
            let brand = setData["brand"] as? String
            
            // PRIORITÉ 1: Match exact (toujours accepté)
            if normalizedNumber.contains("-") {
                // Pour les numéros préfixés, seulement match exact
                for (num, player) in cards {
                    let normalizedNum = num.uppercased()
                        .replacingOccurrences(of: "#", with: "")
                        .replacingOccurrences(of: " ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    
                    if normalizedNum == normalizedNumber {
                        let formattedSetName = formatSetName(setFullName)
                        print("✅ Found by number: [\(num)] → [\(player)] in [\(setFullName)] → formatted: [\(formattedSetName)]")
                        return (player: player, fullSetName: setFullName, brand: brand)
                    }
                }
            } else {
                // Pour les numéros simples, essayer match exact puis flexible
                for (num, player) in cards {
                    let normalizedNum = num.uppercased()
                        .replacingOccurrences(of: "#", with: "")
                        .replacingOccurrences(of: " ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    
                    if normalizedNum == normalizedNumber {
                        let formattedSetName = formatSetName(setFullName)
                        print("✅ Found by number: [\(num)] → [\(player)] in [\(setFullName)] → formatted: [\(formattedSetName)]")
                        return (player: player, fullSetName: setFullName, brand: brand)
                    }
                }
                
                // ❌ FLEXIBLE MATCHING DÉSACTIVÉ - Trop de faux positifs
                // Exemples: "24" matchait "424", "42" matchait "424"
                // On garde seulement le match EXACT ci-dessus
            }
        }
        return nil
    }
    
    // 🎯 PRIORITÉ 1 : Essayer d'abord avec match EXACT d'année
    if let result = searchWithYear(year, exactOnly: true) {
        return result
    }
    
    // 🎯 PRIORITÉ 2 : Si pas trouvé, essayer avec tolérance ±1 an
    if let result = searchWithYear(year, exactOnly: false) {
        return result
    }
    
    // 🎯 PRIORITÉ 3 : FALLBACK - Chercher par numéro + joueur dans TOUS les sets (ignorer année/set)
    // Si le joueur est connu (pas "Unknown") et qu'on a un numéro, chercher la combinaison exacte
    if let playerName = playerName, !playerName.isEmpty && playerName != "Unknown" {
        print("🔄 Fallback: Searching by player name + number across all sets")
        
        for (setFullName, setData) in sets {
            guard let cards = setData["cards"] as? [String: String] else {
                continue
            }
            
            let brand = setData["brand"] as? String
            
            // Chercher le numéro
            for (num, player) in cards {
                let normalizedNum = num.uppercased()
                    .replacingOccurrences(of: "#", with: "")
                    .replacingOccurrences(of: " ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                
                // Match exact du numéro
                if normalizedNum == normalizedNumber {
                    // Comparer les noms de joueurs (ignorer case et accents)
                    let normalizedPlayer = player.folding(options: .diacriticInsensitive, locale: .current).lowercased()
                    let normalizedSearchPlayer = playerName.folding(options: .diacriticInsensitive, locale: .current).lowercased()
                    
                    if normalizedPlayer == normalizedSearchPlayer {
                        print("✅ FALLBACK SUCCESS: Found [\(num)] → [\(player)] in [\(setFullName)] by player+number match")
                        return (player: player, fullSetName: setFullName, brand: brand)
                    }
                }
            }
        }
        
        print("⚠️ Fallback failed: Player [\(playerName)] + number [\(normalizedNumber)] not found")
    }
    
    // ❌ PAS de fallback à 2024-25 si l'année est spécifiée
    // On préfère retourner nil plutôt que le mauvais joueur
    
    print("❌ Card number [\(cardNumber)] not found in local database")
    return nil
}





// MARK: Known NHL player names (1950â€“2025 + HOF)
// Used to validate OCR/eBay-derived player names and prevent set/phrase leakage into the player field.
fileprivate enum KnownPlayerNames {
    // Raw list (one name per line). Generated offline from NHL skaters/defense + goalies + HOF players.
    private static let raw: String = """
A.J. Greer
Aaron Dell
Aaron Downey
Aaron Ekblad
Aaron Gagnon
Aaron Johnson
Aaron MacKenzie
Aaron Ness
Aaron Palushaj
Aaron Rome
Aaron Volpatti
Aaron Voros
Aaron Ward
Aatu Raty
Ace Bailey
Adam Almquist
Adam Beckman
Adam Boqvist
Adam Brooks
Adam Burish
Adam Clendening
Adam Cracknell
Adam Edstrom
Adam Engstrom
Adam Erne
Adam Fantilli
Adam Foote
Adam Fox
Adam Gaudette
Adam Ginning
Adam Hall
Adam Henrique
Adam Huska
Adam Johnson
Adam Klapka
Adam Larsson
Adam Lowry
Adam Mair
Adam McQuaid
Adam Pardy
Adam Payerl
Adam Pelech
Adam Raska
Adam Ruzicka
Adam Werner
Adam Wilcox
Adam Wilsby
Adin Hill
Adrian Aucoin
Adrian Kempe
Aidan McDonough
Akil Thomas
Akim Aliu
Akira Schmid
Akito Hirose
Aku Raty
Al MacInnis
Al Montoya
Alan Quine
Albert Johansson
Alec Connell
Alec Martinez
Alec Regula
Aleksander Barkov
Aleksanteri Kaskimaki
Aleksei Kolosov
Aleksi Heponiemi
Aleksi Saarela
Ales Hemsky
Ales Kotalik
Ales Stezka
Alex Auld
Alex Barr-Boulet
Alex Barre-Boulet
Alex Belzile
Alex Biega
Alex Broadhurst
Alex Chiasson
Alex DeBrincat
Alex Delvecchio
Alex Formenton
Alex Friesen
Alex Frolov
Alex Galchenyuk
Alex Goligoski
Alex Grant
Alex Henry
Alex Iafallo
Alex Kerfoot
Alex Khokhlachev
Alex Killorn
Alex Kovalev
Alex Laferriere
Alex Lyon
Alex Nedeljkovic
Alex Newhook
Alex Nylander
Alex Ovechkin
Alex Petrovic
Alex Pietrangelo
Alex Plante
Alex Stalock
Alex Steeves
Alex Tanguay
Alex Tuch
Alex Turcotte
Alex Vlasic
Alex Wennberg
Alexandar Georgiev
Alexander Alexeyev
Alexander Barabanov
Alexander Burmistrov
Alexander Chmelevski
Alexander Edler
Alexander Holtz
Alexander Kerfoot
Alexander Nikishin
Alexander Nikulin
Alexander Nylander
Alexander Pechurskiy
Alexander Petrovic
Alexander Radulov
Alexander Romanov
Alexander Salak
Alexander Semin
Alexander Steen
Alexander Sulzer
Alexander True
Alexander Urbom
Alexander Vasyunov
Alexander Volkov
Alexander Wennberg
Alexander Yelesin
Alexandre Bolduc
Alexandre Burrows
Alexandre Carrier
Alexandre Fortin
Alexandre Giroux
Alexandre Grenier
Alexandre Picard
Alexandre Texier
Alexei Emelin
Alexei Melnichuk
Alexei Ponikarovsky
Alexei Semenov
Alexei Toropchenko
Alexey Marchenko
Alexey Toropchenko
Alexis Lafreniere
Alexis Lafrenire
Alf Smith
Aliaksei Protas
Allan Stanley
Allen York
Anders Bjork
Anders Eriksson
Anders Lee
Anders Lindback
Anders Nilsson
Andre Benoit
Andre Burakovsky
Andre Deveaux
Andre Lee
Andre Petersson
Andre Roy
Andreas Athanasiou
Andreas Borgman
Andreas Englund
Andreas Engqvist
Andreas Johnsson
Andreas Lilja
Andreas Martinsen
Andreas Nodl
Andreas Thuresson
Andrei Chibisov
Andrei Kostitsyn
Andrei Kuzmenko
Andrei Loktionov
Andrei Markov
Andrei Mironov
Andrei Svechnikov
Andrei Vasilevskiy
Andrej Meszaros
Andrej Nestrasil
Andrej Sekera
Andrej Sustr
Andrew Agozzino
Andrew Alberts
Andrew Bodnarchuk
Andrew Brunette
Andrew Campbell
Andrew Cogliano
Andrew Copp
Andrew Crescenzi
Andrew Desjardins
Andrew Ebbett
Andrew Ference
Andrew Gordon
Andrew Hammond
Andrew Hutchinson
Andrew Joudrey
Andrew Ladd
Andrew MacDonald
Andrew MacWilliam
Andrew Mangiapane
Andrew Miller
Andrew Murray
Andrew Peeke
Andrew Peters
Andrew Poturalski
Andrew Raycroft
Andrew Shaw
Andrey Makarov
Andrey Pedan
Andrey Zubarev
Andy Andreoff
Andy Bathgate
Andy Greene
Andy Hilbert
Andy McDonald
Andy Miele
Andy Sutton
Andy Welinski
Andy Wozniewski
Angela James
Angus Crookshank
Anssi Salmela
Antero Niittymaki
Anthony Angello
Anthony Beauvillier
Anthony Bitetto
Anthony Cirelli
Anthony Duclair
Anthony Greco
Anthony Mantha
Anthony Peluso
Anthony Richard
Anthony Stewart
Anthony Stolarz
Antoine Bibeau
Antoine Roussel
Antoine Vermette
Anton Babchuk
Anton Belov
Anton Blidh
Anton Forsberg
Anton Khudobin
Anton Klementyev
Anton Lander
Anton Levtchi
Anton Lindholm
Anton Lundell
Anton Rodin
Anton Slepyshev
Anton Stralman
Anton Volchenkov
Anton Wedin
Antti Miettinen
Antti Niemi
Antti Pihlstrom
Antti Raanta
Antti Suomela
Anze Kopitar
Arber Xhekaj
Arnaud Durandeau
Arron Asham
Arseny Gritsyuk
Arshdeep Bains
Art Coulter
Art Farrell
Art Ross
Artem Anisimov
Artem Zub
Artemi Kniazev
Artemi Panarin
Arthur Kaliyev
Arttu Hyry
Arttu Ruotsalainen
Artturi Lehkonen
Artur Akhtyamov
Arturs Kulda
Arturs Silovs
Artyom Levshunov
Artyom Zagidulin
Arvid Soderblom
Ashton Sautner
Aurel Joliat
Austin Czarnik
Austin Poganski
Austin Strand
Austin Wagner
Austin Watson
Auston Matthews
Axel Jonsson-Fjallby
Axel Sandin-Pellikka
Aydar Suniev
B.J. Crombeen
Babe Dye
Babe Pratt
Babe Siebert
Barclay Goodrow
Barney Stanley
Barret Jackman
Barrett Hayton
Barry Tallackson
Beau Bennett
Beck Malenstyn
Beckett Sennecke
Ben Bishop
Ben Chiarot
Ben Eager
Ben Gleason
Ben Guite
Ben Hanowski
Ben Harpur
Ben Holmstrom
Ben Hutton
Ben Jones
Ben Kindel
Ben Lovejoy
Ben Maxwell
Ben McCartney
Ben Meyers
Ben Ondrus
Ben Scrivens
Ben Sexton
Ben Smith
Ben Street
Ben Thomas
Ben Thomson
Ben Walter
Benn Ferriero
Benoit Pouliot
Benoit-Olivier Groulx
Berkly Catton
Bernie Federko
Bernie Geoffrion
Bernie Parent
Bert Olmstead
Bill Arnold
Bill Barber
Bill Cook
Bill Cowley
Bill Durnan
Bill Gadsby
Bill Guerin
Bill Mosienko
Bill Quackenbush
Bill Sweatt
Bill Thomas
Billy Burch
Billy Gilmour
Billy McGimsie
Billy Smith
Billy Sweezey
Blair Betts
Blair Jones
Blair Russell
Blake Coleman
Blake Comeau
Blake Geoffrion
Blake Hillman
Blake Lizotte
Blake Pietila
Blake Speers
Blake Wheeler
Bo Groulx
Bo Horvat
Bob Gainey
Bob Pulford
Bobby Bauer
Bobby Brink
Bobby Butler
Bobby Clarke
Bobby Farnham
Bobby Holik
Bobby Hull
Bobby McMann
Bobby Orr
Bobby Robins
Bobby Ryan
Bobby Sanguinetti
Bogdan Kiselevich
Bogdan Trineyev
Bogdan Yakimov
Bokondji Imama
Boo Nieves
Boone Jenner
Boris Katchouk
Boris Valabik
Borje Salming
Borna Rendulic
Bowen Byram
Bowse Hutton
Boyd Devereaux
Boyd Gordon
Boyd Kane
Bracken Kearns
Brad Boyes
Brad Hunt
Brad Lambert
Brad Lukowich
Brad Malone
Brad Marchand
Brad May
Brad Mills
Brad Park
Brad Richards
Brad Richardson
Brad Staubitz
Brad Stuart
Brad Thiessen
Brad Winchester
Braden Holtby
Braden Schneider
Bradly Nadeau
Brady Austin
Brady Keeper
Brady Martin
Brady Skjei
Brady Tkachuk
Braeden Bowman
Braeden Cootes
Brandon Baddock
Brandon Biro
Brandon Bochenski
Brandon Bollig
Brandon Bussi
Brandon Carlo
Brandon Davidson
Brandon DeFazio
Brandon Dubinsky
Brandon Duhaime
Brandon Gignac
Brandon Gormley
Brandon Hagel
Brandon Halverson
Brandon Kozun
Brandon Manning
Brandon Mashinter
Brandon McMillan
Brandon Montour
Brandon Pirri
Brandon Prust
Brandon Saad
Brandon Scanlin
Brandon Segal
Brandon Sutter
Brandon Tanev
Brandon Yip
Brandt Clarke
Brayden Irwin
Brayden McNabb
Brayden Pachal
Brayden Point
Brayden Schenn
Brayden Tracey
Braydon Coburn
Brendan Bell
Brendan Brisson
Brendan Gallagher
Brendan Gaunce
Brendan Guhle
Brendan Leipsic
Brendan Lemieux
Brendan Mikkelson
Brendan Morrison
Brendan Perlini
Brendan Ranford
Brendan Shanahan
Brendan Shinnimin
Brendan Smith
Brendan Witt
Brendan Woods
Brenden Dillon
Brenden Morrow
Brendon Nash
Brennan Menell
Brennan Othmann
Brent Burns
Brent Johnson
Brent Krahn
Brent Regner
Brent Seabrook
Brent Sopel
Bret Hedican
Brett Bellemore
Brett Berard
Brett Bulmer
Brett Carson
Brett Clark
Brett Connolly
Brett Festerling
Brett Gallant
Brett Howden
Brett Hull
Brett Kulak
Brett Leason
Brett Lebda
Brett Lernout
Brett MacLean
Brett McLean
Brett Murray
Brett Pesce
Brett Ritchie
Brett Seney
Brett Skinner
Brett Sterling
Brett Sutter
Brian Boucher
Brian Boyle
Brian Campbell
Brian Dumoulin
Brian Elliott
Brian Fahey
Brian Ferlin
Brian Flynn
Brian Foster
Brian Gibbons
Brian Gionta
Brian Halonen
Brian Lashoff
Brian Lee
Brian Leetch
Brian McGrattan
Brian O'Neill
Brian Pinho
Brian Pothier
Brian Rafalski
Brian Rolston
Brian Salcido
Brian Strait
Brian Sutherby
Brian Willsie
Brinson Pasichnuk
Brock Boeser
Brock Faber
Brock McGinn
Brock Nelson
Brock Trotter
Brodie Dupont
Brody Sutter
Brogan Rafferty
Brooks Laich
Brooks Orpik
Bruce Stuart
Bruno Gervais
Bryan Allen
Bryan Bickell
Bryan Helmer
Bryan Hextall
Bryan Lerg
Bryan Little
Bryan McCabe
Bryan Rodney
Bryan Rust
Bryan Trottier
Bryce Kindopp
Bryce Salvador
Bryce Van Brabant
Bud Holloway
Buddy O'Connor
Buddy Robinson
Bun Cook
Busher Jackson
Butch Bouchard
Byron Bitz
Byron Froese
C.J. Smith
CJ Suess
Cade Fairchild
Cal Clutterbuck
Cal Foote
Cal O'Reilly
Cal Petersen
Cale Fleury
Cale Makar
Caleb Jones
Calen Addison
Callahan Burke
Calle Jarnkrok
Calle Rosen
Calum Ritchie
Calvin Heeter
Calvin Petersen
Calvin Pickard
Calvin Thurkauf
Calvin de Haan
Cam Atkinson
Cam Barker
Cam Dineen
Cam Fowler
Cam Janssen
Cam Lund
Cam Neely
Cam Paddock
Cam Talbot
Cam Ward
Cam York
Cameron Butler
Cameron Crotty
Cameron Gaunce
Cameron Hillis
Cameron Hughes
Cameron Schilling
Cammi Granato
Carey Price
Carl Dahlstrom
Carl Grundstrom
Carl Gunnarsson
Carl Hagelin
Carl Klingberg
Carl Lindbom
Carl Sneep
Carl Soderberg
Carlo Colaiacovo
Carsen Twarynski
Carson Lambos
Carson McMillan
Carson Meyer
Carson Soucy
Carter Ashton
Carter Bancks
Carter Camper
Carter Hart
Carter Hutton
Carter Mazur
Carter Rowney
Carter Verhaeghe
Casey Bailey
Casey Borer
Casey Cizikas
Casey DeSmith
Casey Fitzgerald
Casey Mittelstadt
Casey Nelson
Casey Wellman
Cayden Primeau
Cedric Paquette
Cedrick Desjardins
Chad Billins
Chad Johnson
Chad Kolarik
Chad LaRose
Chad Rau
Chad Ruhwedel
Chandler Stephenson
Charle-Edouard D'Astous
Charles Alexis Legault
Charles Hudon
Charles Linglet
Charlie Conacher
Charlie Coyle
Charlie Gardiner
Charlie Lindgren
Charlie McAvoy
Chase Balisy
Chase Bradley
Chase De Leo
Chase Pearson
Chase Priskie
Chay Genoway
Ching Johnson
Chris Bigras
Chris Bourque
Chris Breen
Chris Brown
Chris Butler
Chris Campoli
Chris Chelios
Chris Clark
Chris Conner
Chris Driedger
Chris Drury
Chris Durno
Chris Gratton
Chris Higgins
Chris Holt
Chris Kelly
Chris Kreider
Chris Kunitz
Chris Mason
Chris Minard
Chris Mueller
Chris Neil
Chris Osgood
Chris Phillips
Chris Porter
Chris Pronger
Chris Stewart
Chris Summers
Chris Tanev
Chris Terry
Chris Thorburn
Chris Tierney
Chris VandeVelde
Chris Wagner
Chris Wideman
Christian Backman
Christian Djoos
Christian Dvorak
Christian Ehrhoff
Christian Fischer
Christian Folin
Christian Hanson
Christian Jaros
Christian Thomas
Christian Wolanin
Christoffer Ehn
Christoph Bertschy
Christoph Schubert
Christopher DiDomenico
Christopher Gibson
Christopher Tanev
Chuck Kobasew
Chuck Rayner
Clark Bishop
Clark Gillies
Clarke MacArthur
Claude Giroux
Claude Lemieux
Clay Stevenson
Clay Wilson
Clayton Keller
Clayton Stoner
Clint Benedict
Clint Smith
Cody Almond
Cody Bass
Cody Ceci
Cody Eakin
Cody Franson
Cody Glass
Cody Goloubef
Cody Hodgson
Cody Kunyk
Cody McCormick
Cody McLeod
Colby Armstrong
Colby Cave
Colby Cohen
Colby Robak
Cole Bardreau
Cole Caufield
Cole Guttman
Cole Koepke
Cole McWard
Cole Perfetti
Cole Reinhardt
Cole Schneider
Cole Schwindt
Cole Sillinger
Cole Smith
Colin Blackwell
Colin Fraser
Colin Greening
Colin McDonald
Colin Miller
Colin Smith
Colin Stuart
Colin White
Colin Wilson
Collin Delia
Collin Graf
Colten Ellis
Colten Teubert
Colton Dach
Colton Gillies
Colton Orr
Colton Parayko
Colton Sceviour
Colton Sissons
Colton White
Connor Bedard
Connor Brickley
Connor Brown
Connor Bunnaman
Connor Carrick
Connor Clattenburg
Connor Clifton
Connor Dewar
Connor Hellebuyck
Connor Ingram
Connor James
Connor Jones
Connor Knapp
Connor Mackey
Connor McDavid
Connor McMichael
Connor Murphy
Connor Zary
Conor Allen
Conor Garland
Conor Geekie
Conor Sheary
Conor Timmins
Cooney Weiland
Cooper Marody
Corban Knight
Corey Crawford
Corey Elkins
Corey Locke
Corey Perry
Corey Potter
Corey Schueneman
Corey Tropp
Cory Conacher
Cory Emmerton
Cory Murphy
Cory Sarich
Cory Schneider
Cory Stillman
Craig Adams
Craig Anderson
Craig Conroy
Craig Cunningham
Craig MacDonald
Craig Rivet
Craig Smith
Craig Weller
Cristobal Huet
Cristopher Nilstorp
Curtis Douglas
Curtis Glencross
Curtis Hamilton
Curtis Joseph
Curtis Lazar
Curtis McElhinney
Curtis McKenzie
Curtis Sanford
Curtis Valk
Cutter Gauthier
Cy Denneny
Cyclone Taylor
DJ King
Daemon Hunt
Dainius Zubrus
Dakota Joshua
Dakota Mermis
Dale Hawerchuk
Dale Weise
Dalibor Dvorsky
Dalton Prout
Dalton Smith
Damien Brunner
Damien Giroux
Damon Severson
Dan Bain
Dan Boyle
Dan Ellis
Dan Fritsche
Dan Girardi
Dan Hamhuis
Dan Hinote
Dan Jancevski
Dan Lacouture
Dan Renouf
Dan Sexton
Dan Vladar
Dana Tyrell
Dane Byers
Danick Martel
Daniel Alfredsson
Daniel Bang
Daniel Brickley
Daniel Briere
Daniel Carcillo
Daniel Carr
Daniel Catenacci
Daniel Cleary
Daniel Lacosta
Daniel O'Regan
Daniel Paille
Daniel Sedin
Daniel Sprong
Daniel Taylor
Daniel Tjarnqvist
Daniel Walcott
Daniel Winnik
Daniil But
Daniil Miromanov
Daniil Misyul
Daniil Tarasov
Danil Gushchin
Danil Yurtaykin
Danil Zhilkin
Danila Yurov
Danny Biega
Danny DeKeyser
Danny Irmen
Danny O'Regan
Danny Syvret
Dante Fabbro
Danton Heinen
Dany Heatley
Dany Sabourin
Darcy Hordichuk
Darcy Kuemper
Darcy Tucker
Darnell Nurse
Darren Archibald
Darren Dietz
Darren Haydar
Darren Helm
Darren McCarty
Darren Raddysh
Darroll Powe
Darryl Boyce
Darryl Sittler
Darryl Sydor
Dave Bolland
Dave Dziurzynski
Dave Keon
Dave Scatchard
David Backes
David Booth
David Broll
David Clarkson
David Desharnais
David Farrance
David Gust
David Gustafsson
David Hale
David Jiricek
David Jones
David Kampf
David Kase
David Koci
David Krejci
David Laliberte
David Legwand
David Leneveu
David Liffiton
David McIntyre
David Moss
David Musil
David Pastrnak
David Perron
David Rittich
David Rundblad
David Savard
David Schlemko
David Sloane
David Spacek
David Steckel
David Tomasek
David Ullstrom
David Van Der Gulik
David Warsofsky
David Wolf
Davis Drewiske
Dawson Mercer
Daymond Langkow
Dean Arsene
Dean Kukan
Dean McAmmond
Declan Carlile
Declan Chisholm
Denis Gauthier
Denis Grebeshkov
Denis Gurianov
Denis Malgin
Denis Potvin
Denis Savard
Dennis Cholowski
Dennis Everberg
Dennis Gilbert
Dennis Hildeby
Dennis Rasmussen
Dennis Seidenberg
Dennis Wideman
Denton Mateychuk
Denver Barkey
Derek Armstrong
Derek Boogaard
Derek Dorsett
Derek Forbort
Derek Grant
Derek Joslin
Derek MacKenzie
Derek Meech
Derek Morris
Derek Peltier
Derek Roy
Derek Ryan
Derek Smith
Derek Stepan
Derek Whitmore
Derick Brassard
Derrick Pouliot
Deryk Engelland
Devan Dubnyk
Devante Smith-Pelly
Devin Cooley
Devin Kaplan
Devin Setoguchi
Devin Shore
Devon Levi
Devon Toews
Dick Duff
Dick Irvin
Dickie Boon
Dickie Moore
Didier Pitre
Dillon Dube
Dillon Heatherington
Dillon Simpson
Dino Ciccarelli
Dion Phaneuf
Dit Clapper
Dmitri Kalinin
Dmitri Samorukov
Dmitri Simashev
Dmitri Voronkov
Dmitrij Jaskin
Dmitry Korobov
Dmitry Kulikov
Dmitry Orlov
Dmytro Timashov
Domenick Fensore
Dominic James
Dominic Moore
Dominic Toninato
Dominic Turgeon
Dominik Kahun
Dominik Kubalik
Dominik Shine
Dominik Simon
Dominik Uher
Donald Brashear
Donovan Sebrango
Doug Bentley
Doug Gilmour
Doug Harvey
Doug Janik
Doug Weight
Dougie Hamilton
Douglas Murray
Drake Batherson
Drake Caggiula
Drake Rymsha
Drayson Bowman
Drew Bagnall
Drew Commesso
Drew Doughty
Drew Helleson
Drew Larman
Drew LeBlanc
Drew MacIntyre
Drew Miller
Drew O'Connor
Drew Shore
Drew Stafford
Dryden Hunt
Duke Keats
Duncan Keith
Duncan Siemens
Dustin Boyd
Dustin Brown
Dustin Byfuglien
Dustin Jeffrey
Dustin Kohn
Dustin Penner
Dustin Tokarski
Dustin Wolf
Dwayne Roloson
Dwight Helminen
Dwight King
Dylan Coghlan
Dylan Cozens
Dylan DeMelo
Dylan Duke
Dylan Ferguson
Dylan Gambrell
Dylan Guenther
Dylan Holloway
Dylan Larkin
Dylan McIlrath
Dylan Olsen
Dylan Reese
Dylan Samberg
Dylan Sikura
Dylan Strome
Dylan Wells
Dysin Mayo
Earl Seibert
Easton Cowan
Ebbie Goodfellow
Ed Belfour
Ed Giacomin
Ed Jovanovski
Eddie Gerard
Eddie Lack
Eddie Shore
Edgar Laprade
Edward Pasquale
Eeli Tolvanen
Eetu Luostarinen
Eetu Makiniemi
Egor Afanasyev
Egor Chinakhov
Egor Korshkov
Egor Sokolov
Egor Yakovlev
Egor Zamula
Elias Lindholm
Elias Pettersson
Elias Salomonsson
Elliot Desnoyers
Elmer Lach
Elmer Soderblom
Elvis Merzlikins
Emerson Etem
Emil Andrae
Emil Bemstrom
Emil Heineman
Emil Lilleberg
Emile Poirier
Emmitt Finnie
Enver Lisin
Eriah Hayes
Eric Belanger
Eric Boulton
Eric Brewer
Eric Comrie
Eric Fehr
Eric Gelinas
Eric Godard
Eric Gryba
Eric Nystrom
Eric O'Dell
Eric Perrin
Eric Robinson
Eric Selleck
Eric Staal
Eric Tangradi
Eric Wellwood
Erik Brannstrom
Erik Burgdoerfer
Erik Cernak
Erik Christensen
Erik Cole
Erik Condra
Erik Ersberg
Erik Gudbranson
Erik Gustafsson
Erik Haula
Erik Johnson
Erik Kallgren
Erik Karlsson
Erik Portillo
Erik Reitz
Ernie Russell
Esa Lindell
Ethan Bear
Ethan Cardwell
Ethan Del Mastro
Ethan Moreau
Ethan Prow
Ethen Frank
Evan Bouchard
Evan Brophey
Evan McEneny
Evan Oberg
Evan Rodrigues
Evander Kane
Evgeni Malkin
Evgeni Nabokov
Evgenii Dadonov
Evgeny Artyukhin
Evgeny Dadonov
Evgeny Grachev
Evgeny Kuznetsov
Evgeny Medvedev
Evgeny Svechnikov
Fabian Brunnstrom
Fabian Lysell
Fabian Zetterlund
Fedor Svechkov
Fedor Tyutin
Felix Sandstrom
Fern Flaman
Fernando Pisani
Filip Chlapik
Filip Chytil
Filip Forsberg
Filip Gustavsson
Filip Hallander
Filip Hronek
Filip Kral
Filip Kuba
Filip Roos
Filip Zadina
Florian Xhekaj
Francis Bouillon
Francis Lessard
Francis Wathier
Francois Beauchemin
Frank Boucher
Frank Brimsek
Frank Corrado
Frank Foyston
Frank Fredrickson
Frank Mahovlich
Frank McGee
Frank Nazar
Frank Nighbor
Frank Rankin
Frank Vatrano
Frans Nielsen
Frantisek Kaberle
Fraser Minten
Frazer McLaren
Fred Scanlon
Fred Whitcroft
Freddie Hamilton
Freddy Meyer
Freddy Modin
Frederic Allard
Frederic Brunet
Frederic St-Denis
Frederick Gaudreau
Frederik Andersen
Frederik Gauthier
Fredrik Claesson
Fredrik Handemark
Fredrik Karlstrom
Fredrik Norrena
Fredrik Olofsson
Fredrik Sjostrom
Gabe Perreault
Gabriel Bourque
Gabriel Carlsson
Gabriel Dumont
Gabriel Fortier
Gabriel Landeskog
Gabriel Vilardi
Gaetan Haas
Gage Goncalves
Gage Quinney
Garnet Exelby
Garnet Hathaway
Garret Sparks
Garrett Mitchell
Garrett Pilon
Garrett Stafford
Garrett Wilson
Garth Murray
Gary Roberts
Gavin Bayreuther
Gavin Brindley
Gemel Smith
Geoff Kinrade
George Armstrong
George Hainsworth
George Hay
George McNamara
George Parros
George Richardson
Georges Boucher
Georges Laraque
Georges Vezina
Georgi Romanov
Georgii Merkulov
Gerald Mayhew
German Rubtsov
Gerry Cheevers
Gerry Mayhew
Gilbert Brule
Gilbert Perreault
Gilles Senn
Giovanni Fiore
Givani Smith
Glen Metropolit
Glenn Anderson
Glenn Gawdin
Glenn Hall
Gord Roberts
Gordie Drillon
Gordie Howe
Graeme Clarke
Graham Drinkwater
Graham Mink
Grant Clitsome
Grant Fuhr
Grant Hutton
Grant Lewis
Greg De Vries
Greg Mauldin
Greg McKegg
Greg Moore
Greg Nemisz
Greg Pateryn
Greg Rallo
Greg Zanon
Gregory Campbell
Gregory Hofmann
Gregory Stewart
Griffen Molino
Griffin Reinhart
Grigori Denisenko
Guillaume Brisebois
Guillaume Desbiens
Guillaume Latendresse
Guillaume Lefebvre
Gump Worsley
Gustav Forsling
Gustav Lindstrom
Gustav Nyquist
Gustav Olofsson
Guy Lafleur
Guy Lapointe
Hal Gill
Hampus Lindholm
Hap Day
Hap Holmes
Hardy Haman Aktell
Harri Pesonen
Harri Sateri
Harrison Brunicke
Harry Cameron
Harry Howell
Harry Hyland
Harry Lumley
Harry Oliver
Harry Trihey
Harry Watson
Harry Westwick
Harry Zolnierczyk
Harvey Pulford
Hayden Hodgson
Haydn Fleury
Helge Grans
Hendrix Lapierre
Henri Jokiharju
Henri Richard
Henrik Borgstrom
Henrik Haapala
Henrik Karlsson
Henrik Lundqvist
Henrik Samuelsson
Henrik Sedin
Henrik Tallinder
Henrik Zetterberg
Henry Thrun
Herb Gardiner
Herbie Lewis
Hobey Baker
Hod Stuart
Hooley Smith
Howie Morenz
Hudson Fasching
Hugh Jessiman
Hugh Lehman
Hugh McGing
Hugo Alnefelt
Hunter Brzustewicz
Hunter Drew
Hunter Haight
Hunter McKown
Hunter Miska
Hunter Shepard
Hunter Shinkaruk
Hunter Skinner
Ian Cole
Ian Laperriere
Ian McCoshen
Ian Mitchell
Ian Moore
Ian White
Igor Chernyshov
Igor Larionov
Igor Ozhiganov
Igor Shesterkin
Iiro Pakarinen
Iiro Tarkki
Ilkka Heikkinen
Ilkka Pikkarainen
Ilya Bryzgalov
Ilya Kovalchuk
Ilya Lyubushkin
Ilya Mikheyev
Ilya Samsonov
Ilya Solovyov
Ilya Sorokin
Ilya Zubov
Isaac Howard
Isaac Ratcliffe
Isaak Phillips
Isac Lundestrm
Isac Lundestrom
Isaiah George
Isak Rosen
Ivan Barbashev
Ivan Chekhovich
Ivan Demidov
Ivan Fedotov
Ivan Ivan
Ivan Miroshnichenko
Ivan Prosvetov
Ivan Provorov
Ivan Vishnevskiy
J-F Berube
J-P Dumont
J.C. Beaudin
J.F. Berube
J.J. Moser
J.T. Brown
J.T. Compher
J.T. Miller
JC Lipon
JJ Peterka
JT Wyman
Jaccob Slavin
Jack Adams
Jack Ahcan
Jack Campbell
Jack Darragh
Jack Devine
Jack Drury
Jack Eichel
Jack Finley
Jack Hillen
Jack Hughes
Jack Johnson
Jack LaFontaine
Jack Laviolette
Jack Marshall
Jack McBain
Jack Quinn
Jack Rathbone
Jack Rodewald
Jack Roslovic
Jack Ruttan
Jack Skille
Jack St. Ivany
Jack Stewart
Jack Studnicka
Jack Thompson
Jack Walker
Jack Williams
Jackson Blake
Jackson Cates
Jackson LaCombe
Jacob Bernard-Docker
Jacob Bryson
Jacob De La Rose
Jacob Fowler
Jacob Gaucher
Jacob Josefson
Jacob Larsson
Jacob Lucchini
Jacob MacDonald
Jacob Markstrom
Jacob Melanson
Jacob Middleton
Jacob Moverare
Jacob Nilsson
Jacob Perreault
Jacob Peterson
Jacob Quillan
Jacob Trouba
Jacques Laperriere
Jacques Lemaire
Jacques Plante
Jaden Schwartz
Jaime Sifers
Jake Allen
Jake Bean
Jake Bischoff
Jake Chelios
Jake Christiansen
Jake DeBrusk
Jake Dotchin
Jake Dowell
Jake Evans
Jake Gardiner
Jake Guentzel
Jake Leschyshyn
Jake Livingstone
Jake Lucchini
Jake McCabe
Jake Middleton
Jake Muzzin
Jake Neighbours
Jake Oettinger
Jake Sanderson
Jake Virtanen
Jake Walman
Jakob Chychrun
Jakob Forsbacka Karlsson
Jakob Lilja
Jakob Pelletier
Jakob Silfverberg
Jakub Dobes
Jakub Galvas
Jakub Jerabek
Jakub Kindl
Jakub Lauko
Jakub Nakladal
Jakub Petruzalek
Jakub Skarek
Jakub Voracek
Jakub Vrana
Jakub Zboril
Jalen Chatfield
Jamal Mayers
James Hamblin
James Malatesta
James Neal
James Reimer
James Sheppard
James Wisniewski
James Wright
James van Riemsdyk
Jamie Arniel
Jamie Benn
Jamie Devane
Jamie Doornbosch
Jamie Drysdale
Jamie Fraser
Jamie Fritsch
Jamie Heward
Jamie Langenbrunner
Jamie Lundmark
Jamie McBain
Jamie McGinn
Jamie Oleksiak
Jamie Tardif
Jan Hejda
Jan Jenik
Jan Mursak
Jan Rutta
Jani Hakanp
Jani Hakanpaa
Jani Nyman
Janis Sprukts
Janne Kuokkanen
Janne Niskala
Janne Pesonen
Jannik Hansen
Jansen Harkins
Jared Boll
Jared Coreau
Jared Cowen
Jared Davidson
Jared McCann
Jared Ross
Jared Spurgeon
Jared Staal
Jaret Anderson-Dolan
Jari Kurri
Jarkko Ruutu
Jarod Palmer
Jarome Iginla
Jaromir Jagr
Jaroslav Chmelar
Jaroslav Halak
Jaroslav Spacek
Jarred Tinordi
Jarret Stoll
Jason Akeson
Jason Arnott
Jason Blake
Jason Chimera
Jason Demers
Jason Dickinson
Jason Garrison
Jason Jaffray
Jason Kasdorf
Jason Krog
Jason LaBarbera
Jason Polin
Jason Pominville
Jason Robertson
Jason Smith
Jason Spezza
Jason Strudwick
Jason Ward
Jason Williams
Jason Zucker
Jasper Weatherby
Jassen Cullimore
Jaxson Stauber
Jay Beagle
Jay Bouwmeester
Jay Harrison
Jay Leach
Jay McClement
Jay McKee
Jay Pandolfo
Jay Rosehill
Jayce Hawryluk
Jaycob Megna
Jayden Halbgewachs
Jayden Struble
Jayson Megna
Jean Beliveau
Jean Ratelle
Jean-Francois Jacques
Jean-Gabriel Pageau
Jean-Luc Foudy
Jean-Philippe Cote
Jean-Sebastien Dea
Jean-Sebastien Giguere
Jed Ortmeyer
Jeff Carter
Jeff Deslauriers
Jeff Finger
Jeff Frazee
Jeff Glass
Jeff Halpern
Jeff Hamilton
Jeff Hoggan
Jeff Malott
Jeff Penner
Jeff Petry
Jeff Schultz
Jeff Skinner
Jeff Taffe
Jeff Tambellini
Jeff Woywitka
Jeff Zatkoff
Jeffrey Viel
Jere Innala
Jere Lehtinen
Jeremy Colliton
Jeremy Davies
Jeremy Duchesne
Jeremy Lauzon
Jeremy Morin
Jeremy Roenick
Jeremy Smith
Jeremy Swayman
Jeremy Welsh
Jeremy Williams
Jerome Samson
Jerred Smithson
Jerry D'Amigo
Jesper Boqvist
Jesper Bratt
Jesper Fast
Jesper Froden
Jesper Wallstedt
Jesperi Kotkaniemi
Jesse Blacker
Jesse Boulerice
Jesse Joensuu
Jesse Puljujarvi
Jesse Winchester
Jesse Ylnen
Jesse Ylonen
Jet Greaves
Jett Alexander
Jett Luchanko
Jhonas Enroth
Jim Gardner
Jim O'Brien
Jim Slater
Jim Vandermeer
Jimmy Hayes
Jimmy Howard
Jimmy Schuldt
Jimmy Snuggerud
Jimmy Vesey
Jiri Hudler
Jiri Kulich
Jiri Novotny
Jiri Patera
Jiri Sekac
Jiri Smejkal
Jiri Tlusty
Joachim Blichfeld
Joacim Eriksson
Joakim Andersson
Joakim Kemell
Joakim Lindstrom
Joakim Nordstrom
Joakim Nygard
Joakim Ryan
Jochen Hecht
Jody Shelley
Joe Callahan
Joe Colborne
Joe Corvo
Joe Finley
Joe Hall
Joe Hicketts
Joe Malone
Joe Morrow
Joe Mullen
Joe Nieuwendyk
Joe Pavelski
Joe Piskula
Joe Primeau
Joe Sakic
Joe Simpson
Joe Snively
Joe Thornton
Joe Veleno
Joe Vitale
Joe Whitney
Joel Armia
Joel Blomqvist
Joel Edmundson
Joel Eriksson Ek
Joel Farabee
Joel Hanley
Joel Hofer
Joel Kellman
Joel Kiviranta
Joel L'Esperance
Joel Lundqvist
Joel Nystrom
Joel Perrault
Joel Persson
Joel Rechlicz
Joel Teasdale
Joel Vermin
Joel Ward
Joey Anderson
Joey Crabb
Joey Daccord
Joey Hishon
Joey Keane
Joey MacDonald
Joffrey Lupul
Johan Backlund
Johan Franzen
Johan Harju
Johan Hedberg
Johan Larsson
Johan Motin
Johan Sundstrom
John Albert
John Beecher
John Bucyk
John Carlson
John Curry
John Erskine
John Farinacci
John Gibson
John Gilmour
John Hayden
John Klingberg
John Leonard
John Ludvig
John Madden
John Marino
John McCarthy
John McFarland
John Mitchell
John Moore
John Negrin
John Persson
John Quenneville
John Ramage
John Scott
John Tavares
John Zeiler
John-Michael Liles
Johnathan Kovacevic
Johnny Bower
Johnny Boychuk
Johnny Gaudreau
Johnny Oduya
Jon Disalvatore
Jon Gillies
Jon Kalinski
Jon Lizotte
Jon Matsumoto
Jon Merrill
Jon Sim
Jonah Gadjovich
Jonas Andersson
Jonas Brodin
Jonas Frogren
Jonas Gustavsson
Jonas Hiller
Jonas Holos
Jonas Johansson
Jonas Junland
Jonas Rondbjerg
Jonas Siegenthaler
Jonatan Berggren
Jonathan Aspirot
Jonathan Bernier
Jonathan Cheechoo
Jonathan Dahlen
Jonathan Davidsson
Jonathan Drouin
Jonathan Ericsson
Jonathan Gruden
Jonathan Huberdeau
Jonathan Lekkerimki
Jonathan Marchessault
Jonathan Quick
Jonathan Racine
Jonathan Rheault
Jonathan Toews
Jonathon Blum
Joni Ortio
Joni Pitkanen
Jonny Brodzinski
Joona Koppanen
Joona Luoto
Joonas Donskoi
Joonas Kemppainen
Joonas Korpisalo
Joonas Nattinen
Joonas Rask
Jordan Binnington
Jordan Caron
Jordan Eberle
Jordan Greenway
Jordan Gross
Jordan Harris
Jordan Hendry
Jordan Kyrou
Jordan Lavallee-Smotherman
Jordan Leopold
Jordan Martinook
Jordan Nolan
Jordan Oesterle
Jordan Schmaltz
Jordan Schroeder
Jordan Spence
Jordan Staal
Jordan Szwarz
Jordan Weal
Jordie Benn
Jordin Tootoo
Jorge Alves
Jori Lehtera
Jose Theodore
Josef Korenar
Josef Melichar
Joseph Blandisi
Joseph Cramarossa
Joseph Gambardella
Joseph LaBate
Joseph Motzko
Joseph Woll
Josh Anderson
Josh Archibald
Josh Bailey
Josh Brown
Josh Currie
Josh Doan
Josh Dunne
Josh Gorges
Josh Gratton
Josh Green
Josh Harding
Josh Hennessy
Josh Jacobs
Josh Jooris
Josh Leivo
Josh Mahura
Josh Manson
Josh Morrissey
Josh Norris
Josh Teves
Josh Tordjman
Joshua Brown
Joshua Ho-Sang
Joshua Mahura
Joshua Roy
Josiah Slavin
Juha Jaaska
Juho Lammikko
Jujhar Khaira
Julian Melchiori
Julien Brouillette
Julien Gauthier
Julius Honka
Juraj Slafkovsk
Juraj Slafkovsky
Jussi Jokinen
Jussi Rynnas
Justin Abdelkader
Justin Auger
Justin Bailey
Justin Barron
Justin Braun
Justin Brazeau
Justin Danforth
Justin DiBenedetto
Justin Dowling
Justin Falk
Justin Faulk
Justin Florek
Justin Fontaine
Justin Hodgman
Justin Holl
Justin Hryckowian
Justin Johnson
Justin Kirkland
Justin Kloos
Justin Mercier
Justin Peters
Justin Pogge
Justin Richards
Justin Robidas
Justin Schultz
Justin Shugg
Justin Sourdif
Justin Williams
Justus Annunen
Juuse Saros
Juuso Parssinen
Juuso Riikola
Juuso Valimaki
Juuso Vlimki
Jyrki Jokipakka
K'Andre Miller
Kaapo Kahkonen
Kaapo Kakko
Kaden Fulcher
Kaedan Korczak
Kael Mouillierat
Kaiden Guhle
Kailer Yamamoto
Kale Clague
Kalle Kossila
Kamil Kreps
Karel Vejmelka
Kari Lehtonen
Karl Alzner
Karl Stollery
Karlis Skrastins
Karri Ramo
Karsen Dorwart
Karson Kuhlman
Kasimir Kaskisuo
Kaspars Daugavins
Kasper Bjorkqvist
Kasperi Kapanen
Keaton Ellerby
Keaton Middleton
Keegan Kolesar
Keegan Lowe
Keith Aucoin
Keith Aulie
Keith Ballard
Keith Kinkaid
Keith Tkachuk
Keith Yandle
Kellan Lain
Ken Appleby
Ken Dryden
Ken Klee
Ken Reardon
Kenndal McArdle
Kenneth Appleby
Kenny Agostino
Kent Huskins
Kent Johnson
Kent Simpson
Kerby Rychel
Kevan Miller
Kevin Bahl
Kevin Bieksa
Kevin Boyle
Kevin Connauton
Kevin Czuczman
Kevin Fiala
Kevin Gravel
Kevin Hayes
Kevin Henderson
Kevin Klein
Kevin Korchinski
Kevin Labanc
Kevin Lankinen
Kevin Mandolese
Kevin Marshall
Kevin Porter
Kevin Poulin
Kevin Quick
Kevin Rooney
Kevin Roy
Kevin Shattenkirk
Kevin Stenlund
Kevin Weekes
Kevin Westgarth
Kiefer Sherwood
Kieffer Bellows
Kim Johnsson
Kimmo Timonen
King Clancy
Kirby Dach
Kirill Kaprizov
Kirill Kudryavtsev
Kirill Marchenko
Kirill Semyonov
Kirk Maltby
Klas Dahlbeck
Klim Kostin
Kole Lind
Kole Sherwood
Konsta Helenius
Korbinian Holzer
Kris Chucko
Kris Draper
Kris Fredheim
Kris Letang
Kris Newbury
Kris Russell
Kris Versteeg
Kristers Gudlevskis
Kristian Huselius
Kristian Reichel
Kristian Vesalainen
Kristians Rubins
Kristopher Foucault
Krys Barch
Krys Kolanos
Kurt Sauer
Kurtis Foster
Kurtis Gabriel
Kurtis MacDermid
Kurtis McLean
Kyle Baun
Kyle Brodziak
Kyle Burroughs
Kyle Calder
Kyle Capobianco
Kyle Chipchura
Kyle Clifford
Kyle Connor
Kyle Criscuolo
Kyle Cumiskey
Kyle Greentree
Kyle MacLean
Kyle Okposo
Kyle Palmieri
Kyle Quincey
Kyle Rau
Kyle Turris
Kyle Wellwood
Kyle Wilson
Ladislav Smid
Lance Bouma
Landon Bow
Landon Ferraro
Landon Slaggert
Landon Wilson
Lane Hutson
Lane MacDermid
Lane Pederson
Lanny McDonald
Larry Murphy
Larry Robinson
Lars Eller
Lasse Kukkonen
Lassi Thomson
Laurent Brossoit
Laurent Dauphin
Lauri Korpikoski
Lawrence Nycholat
Lawrence Pilut
Lawson Crouse
Lean Bergmann
Lee Stempniak
Lee Sweatt
Leevi Merilainen
Leevi Merilinen
Leland Irving
Lennart Petrell
Lenni Hameenaho
Leo Boivin
Leo Carlsson
Leo Komarov
Leon Draisaitl
Lester Patrick
Liam Foudy
Liam O'Brien
Liam Ohgren
Liam Reddox
Lian Bichsel
Lias Andersson
Libor Hajek
Libor Sulak
Linden Vey
Linus Hogberg
Linus Karlsson
Linus Klasen
Linus Omark
Linus Sandin
Linus Ullmark
Lionel Conacher
Logan Brown
Logan Cooley
Logan Couture
Logan Mailloux
Logan Morrison
Logan O'Connor
Logan Shaw
Logan Stankoven
Logan Stanley
Logan Thompson
Loui Eriksson
Louie Belpedio
Louis Crevier
Louis Domingue
Louis Leblanc
Lubomir Visnovsky
Luc Robitaille
Luca Cagnoni
Luca Caputi
Luca Del Bel Belluz
Luca Pinelli
Luca Sbisa
Lucas Carlsson
Lucas Condotta
Lucas Johansen
Lucas Lessio
Lucas Raymond
Lucas Wallmark
Lukas Cormier
Lukas Dostal
Lukas Kaspar
Lukas Krajicek
Lukas Radil
Lukas Reichel
Lukas Rousek
Lukas Sedlak
Lukas Vejdemo
Luke Adam
Luke Evangelista
Luke Gazdic
Luke Glendening
Luke Hughes
Luke Johnson
Luke Kunin
Luke Philp
Luke Richardson
Luke Schenn
Luke Witkowski
Lynn Patrick
Mac Hollowell
MacGregor Sharp
MacKenzie Entwistle
MacKenzie Weegar
Mackenzie Blackwood
Mackenzie MacEachern
Mackenzie Skapski
Mackie Samoskevich
Macklin Celebrini
Madison Bowey
Mads Sogaard
Magnus Chrona
Magnus Hellberg
Magnus Paajarvi
Maksim Mayorov
Maksim Sushko
Maksymilian Szuber
Malcolm Subban
Manny Fernandez
Manny Legace
Manny Malhotra
Marat Khusnutdinov
Marc Del Gaizo
Marc Denis
Marc Gatcomb
Marc Johnstone
Marc McLaughlin
Marc Methot
Marc Michaelis
Marc Savard
Marc Staal
Marc-Andre Bergeron
Marc-Andre Bourdon
Marc-Andre Cliche
Marc-Andre Fleury
Marc-Andre Gragnani
Marc-Antoine Pouliot
Marc-Edouard Vlasic
Marcel Dionne
Marcel Goc
Marcel Mueller
Marcel Pronovost
Marco Kasper
Marco Rossi
Marco Scandella
Marco Sturm
Marcus Bjork
Marcus Foligno
Marcus Hogberg
Marcus Johansson
Marcus Kruger
Marcus Pettersson
Marcus Sorensen
Marek Hrivik
Marek Langhamer
Marek Malik
Marek Mazanec
Marek Schwarz
Marek Svatos
Marek Zidlicky
Marian Gaborik
Marian Hossa
Marian Studenic
Marin Studenic
Mario Bliznak
Mario Ferraro
Mario Kempe
Mario Lemieux
Mark Alt
Mark Arcobello
Mark Barberio
Mark Bell
Mark Borowiecki
Mark Cullen
Mark Cundari
Mark Dekanich
Mark Eaton
Mark Fayne
Mark Fistric
Mark Flood
Mark Fraser
Mark Friedman
Mark Giordano
Mark Howe
Mark Jankowski
Mark Kastelic
Mark Katic
Mark Letestu
Mark Mancari
Mark McNeill
Mark Messier
Mark Olver
Mark Parrish
Mark Popovic
Mark Pysyk
Mark Recchi
Mark Scheifele
Mark Stone
Mark Streit
Mark Stuart
Mark Van Guilder
Mark Visentin
Marko Dano
Markus Granlund
Markus Hannikainen
Markus Naslund
Markus Niemelainen
Markus Nutivaara
Marshall Rifai
Marshall Warren
Martin Biron
Martin Brodeur
Martin Erat
Martin Fehervary
Martin Fehrvry
Martin Frk
Martin Gerber
Martin Hanzal
Martin Havlat
Martin Jones
Martin Kaut
Martin Marincin
Martin Necas
Martin Pospisil
Martin Skoula
Martin St Pierre
Martin St. Louis
Martins Karsums
Marty Barry
Marty Reasoner
Marty Turco
Marty Walsh
Mason Appleton
Mason Geertsen
Mason Lohrei
Mason Marchment
Mason McTavish
Mason Morelli
Mason Raymond
Mason Shaw
Mat Clark
Matej Blumel
Mathew Barzal
Mathew Dumba
Mathias Brome
Mathieu Carle
Mathieu Dandenault
Mathieu Darche
Mathieu Garon
Mathieu Joseph
Mathieu Olivier
Mathieu Perreault
Mathieu Roy
Mathieu Schneider
Matias Maccelli
Matiss Kivlenieks
Matj Blmel
Mats Sundin
Mats Zuccarello
Matt Anderson
Matt Bartkowski
Matt Beleskey
Matt Benning
Matt Boldy
Matt Bradley
Matt Calvert
Matt Campanale
Matt Carey
Matt Carkner
Matt Carle
Matt Climie
Matt Cooke
Matt Coronato
Matt Cullen
Matt D'Agostini
Matt Donovan
Matt Duchene
Matt Dumba
Matt Ellis
Matt Fraser
Matt Frattin
Matt Gilroy
Matt Greene
Matt Grzelcyk
Matt Hackett
Matt Halischuk
Matt Hendricks
Matt Hunwick
Matt Irwin
Matt Kassian
Matt Kiersted
Matt Lashoff
Matt Lindblad
Matt Lorito
Matt Luff
Matt Martin
Matt Moulson
Matt Murray
Matt Nieto
Matt Niskanen
Matt Pelech
Matt Pettinger
Matt Puempel
Matt Read
Matt Rempe
Matt Roy
Matt Savoie
Matt Smaby
Matt Stajan
Matt Stienburg
Matt Taormina
Matt Tennyson
Matt Tomkins
Matt Villalta
Matt Walker
Matt Watkins
Matt Zaba
Matthew Berlin
Matthew Corrente
Matthew Highmore
Matthew Kessel
Matthew Knies
Matthew Konan
Matthew Lombardi
Matthew O'Connor
Matthew Peca
Matthew Phillips
Matthew Poitras
Matthew Robertson
Matthew Schaefer
Matthew Tkachuk
Matthew Wood
Mattias Ekholm
Mattias Janmark
Mattias Norlinder
Mattias Ohlund
Mattias Ritola
Mattias Samuelsson
Mattias Tedenby
Matty Beniers
Matvei Gridin
Matvei Michkov
Maurice Richard
Maveric Lamoureux
Mavrik Bourque
Max Bentley
Max Comtois
Max Crozier
Max Domi
Max Friberg
Max Jones
Max Lajoie
Max McCormick
Max Pacioretty
Max Reinhart
Max Sasson
Max Sauve
Max Shabanov
Max Talbot
Max Veronneau
Max Willman
Maxence Guenette
Maxim Afinogenov
Maxim Groshev
Maxim Lapierre
Maxim Letunov
Maxim Mamin
Maxim Noreau
Maxim Tsyplakov
Maxime Fortunus
Maxime Lagace
Maxime Lajoie
Maxime Macenauer
Maxwell Crozier
Melker Karlsson
Michael Amadio
Michael Bournival
Michael Brandsegg-Nygrd
Michael Bunting
Michael Callahan
Michael Cammalleri
Michael Carcone
Michael Caruso
Michael Chaput
Michael Dal Colle
Michael Del Zotto
Michael DiPietro
Michael Eyssimont
Michael Frolik
Michael Grabner
Michael Houser
Michael Hutchinson
Michael Kapla
Michael Keranen
Michael Kesselring
Michael Kostka
Michael Latta
Michael Leighton
Michael Matheson
Michael McCarron
Michael McLeod
Michael McNiven
Michael Mersch
Michael Milne
Michael Misa
Michael Nylander
Michael Paliotta
Michael Peca
Michael Pezzetta
Michael Raffl
Michael Rasmussen
Michael Ryan
Michael Ryder
Michael Sauer
Michael Sgarbossa
Michael Stone
Michael Zalewski
Michael Zigomanis
Michal Handzus
Michal Jordan
Michal Kempny
Michal Neuvirth
Michal Repik
Michal Rozsival
Micheal Ferland
Micheal Haley
Michel Goulet
Michel Ouellet
Mickey MacKay
Miikka Kiprusoff
Miikka Salomaki
Mika Pyorala
Mika Zibanejad
Mikael Backlund
Mikael Granlund
Mikael Pyyhtia
Mikael Samuelsson
Mikael Tellqvist
Mike Angelidis
Mike Blunden
Mike Bossy
Mike Brodeur
Mike Brown
Mike Commodore
Mike Comrie
Mike Condon
Mike Connolly
Mike Duco
Mike Fisher
Mike Gartner
Mike Grant
Mike Green
Mike Grier
Mike Halmo
Mike Hardman
Mike Hoffman
Mike Iggulden
Mike Knuble
Mike Komisarek
Mike Liambas
Mike Lundin
Mike Matheson
Mike McKenna
Mike Modano
Mike Moore
Mike Mottau
Mike Murphy
Mike Reilly
Mike Ribeiro
Mike Richards
Mike Rupp
Mike Santorelli
Mike Sillinger
Mike Sislo
Mike Smith
Mike Van Ryn
Mike Vecchione
Mike Vernace
Mike Weaver
Mike Weber
Mike York
Mikey Anderson
Mikhail Grabovski
Mikhail Grigorenko
Mikhail Maltsev
Mikhail Sergachev
Mikhail Vorobyev
Mikkel Boedker
Mikko Koivu
Mikko Koskinen
Mikko Lehtonen
Mikko Rantanen
Milan Hejduk
Milan Jurcina
Milan Kytnar
Milan Lucic
Milan Michalek
Miles Wood
Milos Kelemen
Milt Schmidt
Mirco Mueller
Miro Heiskanen
Miroslav Satan
Mitch Callahan
Mitch Marner
Mitch Reinke
Mitchell Chaffee
Mitchell Fritz
Mitchell Marner
Mitchell Stephens
Moose Goheen
Moose Johnson
Morgan Barron
Morgan Ellis
Morgan Frost
Morgan Geekie
Morgan Klimchuk
Morgan Rielly
Moritz Seider
Nail Yakupov
Nate Danielson
Nate Guenin
Nate Prosser
Nate Raduns
Nate Schmidt
Nate Thompson
Nathan Bastian
Nathan Beaulieu
Nathan Clurman
Nathan Gerbe
Nathan Horton
Nathan Lawson
Nathan Lgar
Nathan Lieuwen
Nathan MacKinnon
Nathan McIver
Nathan Oystrick
Nathan Paetsch
Nathan Smith
Nathan Walker
Nazem Kadri
Neal Pionk
Neil Colville
Nels Stewart
Nelson Nogier
Newsy Lalonde
Nic Dowd
Nic Petan
Nicholas Abruzzese
Nicholas Baptiste
Nicholas Merkley
Nicholas Paul
Nicholas Robertson
Nicholas Shore
Nick Abruzzese
Nick Bjugstad
Nick Blankenburg
Nick Bonino
Nick Boynton
Nick Caamano
Nick Cicek
Nick Cousins
Nick DeSimone
Nick Drazenovic
Nick Foligno
Nick Holden
Nick Jensen
Nick Johnson
Nick Lappin
Nick Lardis
Nick Leddy
Nick Merkley
Nick Palmieri
Nick Paul
Nick Perbix
Nick Petrecki
Nick Ritchie
Nick Schmaltz
Nick Schultz
Nick Seeler
Nick Shore
Nick Sorensen
Nick Spaling
Nick Suzuki
Nick Swaney
Nick Tarnasky
Nicklas Backstrom
Nicklas Grossmann
Nicklas Jensen
Nicklas Lidstrom
Niclas Bergfors
Niclas Havelid
Niclas Wallin
Nico Daws
Nico Hischier
Nico Sturm
Nicolas Aube-Kubel
Nicolas Beaudin
Nicolas Blanchard
Nicolas Deschamps
Nicolas Deslauriers
Nicolas Hague
Nicolas Kerdiles
Nicolas Meloche
Nicolas Roy
Nigel Dawes
Nik Antropov
Nikita Alexandrov
Nikita Chibrikov
Nikita Filatov
Nikita Grebenkin
Nikita Gusev
Nikita Kucherov
Nikita Nesterenko
Nikita Nesterov
Nikita Nikitin
Nikita Okhotiuk
Nikita Prishchepov
Nikita Scherbak
Nikita Soshnikov
Nikita Tolopilo
Nikita Tryamkin
Nikita Zadorov
Nikita Zaitsev
Nikke Kokko
Niklas Backstrom
Niklas Hagman
Niklas Hjalmarsson
Niklas Kronwall
Niklas Svedberg
Niklas Treutle
Niko Mikkola
Nikolai Khabibulin
Nikolai Knyzhov
Nikolai Kovalenko
Nikolai Prokhorkin
Nikolaj Ehlers
Nikolas Matinpalo
Nikolay Goldobin
Nikolay Kulemin
Nikolay Zherdev
Nils Aman
Nils Hoglander
Nils Lundkvist
Nino Niederreiter
Noah Cates
Noah Dobson
Noah Gregor
Noah Hanifin
Noah Juulsen
Noah Laba
Noah Ostlund
Noah Philp
Noah Welch
Noel Acciari
Nolan Allan
Nolan Baumgartner
Nolan Foote
Nolan Patrick
Nolan Yonkman
Norm Ullman
Ole-Kristian Tollefsen
Olen Zellweger
Olie Kolzig
Oliver Bjorkstrand
Oliver Ekman-Larsson
Oliver Kapanen
Oliver Kylington
Oliver Lauridsen
Oliver Moore
Oliver Seibert
Oliver Wahlstrom
Olivier Magnan
Olivier Rodrigue
Olle Alsing
Olle Eriksson Ek
Olle Lycksell
Olli Jokinen
Olli Juolevi
Olli Maatta
Olli Mtt
Ondrej Kase
Ondrej Palat
Ondrej Pavel
Ondrej Pavelec
Oscar Dansk
Oscar Fantenberg
Oscar Fisker Molgaard
Oscar Klefbom
Oscar Lindberg
Oscar Moller
Oskar Bck
Oskar Lindblom
Oskar Olausson
Oskar Osala
Oskar Steen
Oskar Sundqvist
Oskars Bartulis
Ossi Vaananen
Otto Koivula
Otto Leskinen
Otto Stenberg
Owen Beck
Owen Nolan
Owen Pickering
Owen Power
Owen Sillinger
Owen Tippett
Ozzy Wiesblatt
P.J. Axelsson
P.K. Subban
P.O Joseph
PA Parenteau
Paddy Moran
Par Lindholm
Parker Ford
Parker Kelly
Parker Wotherspoon
Pascal Dupuis
Pascal Leclaire
Pascal Pelletier
Pat LaFontaine
Pat Maroon
Patric Hornqvist
Patrice Bergeron
Patrice Brisebois
Patrice Cormier
Patrick Bordeleau
Patrick Brown
Patrick Cannone
Patrick Davis
Patrick Dwyer
Patrick Eaves
Patrick Giles
Patrick Holland
Patrick Kaleta
Patrick Kane
Patrick Lalime
Patrick Marleau
Patrick Maroon
Patrick O'Sullivan
Patrick Rissmiller
Patrick Roy
Patrick Russell
Patrick Sharp
Patrick Sieloff
Patrick Wey
Patrick Wiercioch
Patrik Berglund
Patrik Elias
Patrik Koch
Patrik Laine
Patrik Nemeth
Paul Bissonnette
Paul Byron
Paul Carey
Paul Coffey
Paul Cotter
Paul Gaustad
Paul Kariya
Paul LaDue
Paul Mara
Paul Martin
Paul Postma
Paul Ranger
Paul Stastny
Paul Szczechura
Paul Thompson
Pavel Buchnevich
Pavel Datsyuk
Pavel Dorofeyev
Pavel Francouz
Pavel Kubina
Pavel Mintyukov
Pavel Zacha
Pavol Demitra
Pavol Regenda
Pekka Rinne
Per Ledin
Percy LeSueur
Perttu Lindgren
Peter Budaj
Peter Cehlarik
Peter Forsberg
Peter Harrold
Peter Holland
Peter LeBlanc
Peter Mannino
Peter Mueller
Peter Olvecky
Peter Regin
Peter Schaefer
Peter Stastny
Petr Kalus
Petr Mrazek
Petr Prucha
Petr Straka
Petr Sykora
Petr Vrana
Petter Granberg
Petteri Lindbohm
Petteri Nokelainen
Peyton Krebs
Phat Wilson
Pheonix Copley
Phil Esposito
Phil Kessel
Phil Oreskovic
Phil Varone
Philip Broberg
Philip Holm
Philip Kemp
Philip Larsen
Philip McRae
Philip Samuelsson
Philip Tomasino
Philipp Grubauer
Philipp Kurashev
Philippe Boucher
Philippe Cornet
Philippe Dupuis
Philippe Maillet
Philippe Myers
Phillip Danault
Phillip Di Giuseppe
Pierre Engvall
Pierre Pilote
Pierre-Cedric Labrie
Pierre-Edouard Bellemare
Pierre-Luc Dubois
Pierre-Luc Letourneau-Leblond
Pierre-Marc Bouchard
Pierre-Olivier Joseph
Pierrick Dube
Pius Suter
Pontus Aberg
Pontus Holmberg
Punch Broadbent
Pyotr Kochetkov
Quinn Hughes
Quinn Hutson
Quintin Laing
Quinton Byfield
Quinton Howden
R.J. Umberger
Radek Bonk
Radek Dvorak
Radek Faksa
Radek Martinek
Radek Smolenak
Radim Simek
Radim Vrbata
Radim Zohorna
Radko Gudas
Rafael Harvey-Pinard
Raffi Torres
Raitis Ivanans
Raman Hrabarenka
Randy Jones
Raphael Diaz
Raphael Lavoie
Rasmus Andersson
Rasmus Asplund
Rasmus Dahlin
Rasmus Kupari
Rasmus Rissanen
Rasmus Ristolainen
Rasmus Sandin
Ray Emery
Ray Macias
Ray Whitney
Raymond Bourque
Raymond Sawada
Red Dutton
Red Horner
Red Kelly
Reese Johnson
Reg Noble
Reid Boucher
Reid Schaefer
Reilly Smith
Reilly Walsh
Rem Pitlick
Remi Elie
Rene Bourque
Reto Berra
Rhett Gardner
Rhett Rakhshani
Rich Clune
Rich Peverley
Richard Bachman
Richard Panik
Richard Park
Richard Petiot
Richard Zednik
Rick DiPietro
Rick Nash
Rick Rypien
Rickard Rakell
Rickard Wallin
Ridly Greig
Riku Helenius
Riley Armstrong
Riley Barber
Riley Cote
Riley Damiani
Riley Duran
Riley Hern
Riley Nash
Riley Sheahan
Riley Stillman
Riley Tufte
Rinat Valiev
Rob Blake
Rob Davison
Rob Klinkhammer
Rob Niedermayer
Rob O'Gara
Rob Schremp
Rob Scuderi
Rob Zepp
Robbie Earl
Robbie Russo
Robby Fabbri
Robert Bortuzzo
Robert Hagg
Robert Lang
Robert Nilsson
Robert Thomas
Roberto Luongo
Robin Lehner
Robin Salo
Roby Jarventie
Robyn Regehr
Rocco Grimaldi
Rod Brind'Amour
Rod Gilbert
Rod Langway
Rod Pelley
Rodrigo Abols
Roland McKeown
Roman Cervenka
Roman Hamrlik
Roman Horak
Roman Josi
Roman Lyubimov
Roman Polak
Roman Wick
Roman Will
Ron Francis
Ron Hainsey
Ronalds Kenins
Ronnie Attard
Roope Hintz
Rory Kerins
Ross Colton
Ross Johnston
Rostislav Klesla
Rostislav Olesz
Rourke Chartier
Roy Conacher
Roy Worters
Rudolfs Balcers
Ruslan Fedotenko
Ruslan Iskhakov
Ruslan Salei
Russell Bowie
Rusty Crawford
Rutger McGroarty
Ryan Bayda
Ryan Bourque
Ryan Callahan
Ryan Carpenter
Ryan Carter
Ryan Craig
Ryan Donato
Ryan Dzingel
Ryan Ellis
Ryan Garbutt
Ryan Getzlaf
Ryan Graves
Ryan Greene
Ryan Hamilton
Ryan Hartman
Ryan Hollweg
Ryan Johansen
Ryan Johnson
Ryan Johnston
Ryan Jones
Ryan Keller
Ryan Kesler
Ryan Kuffner
Ryan Leonard
Ryan Lindgren
Ryan Lomberg
Ryan MacInnis
Ryan Malone
Ryan McDonagh
Ryan McLeod
Ryan Merkley
Ryan Miller
Ryan Murphy
Ryan Murray
Ryan Nugent-Hopkins
Ryan O'Byrne
Ryan O'Marra
Ryan O'Reilly
Ryan Parent
Ryan Poehling
Ryan Potulny
Ryan Pulock
Ryan Reaves
Ryan Russell
Ryan Shannon
Ryan Shea
Ryan Smyth
Ryan Spooner
Ryan Sproul
Ryan Stanton
Ryan Stoa
Ryan Stone
Ryan Strome
Ryan Suter
Ryan Suzuki
Ryan Thang
Ryan Ufko
Ryan Vesce
Ryan White
Ryan Whitney
Ryan Wilson
Ryan Winterton
Ryane Clowe
Ryker Evans
Saku Koivu
Saku Maenalanen
Sam Bennett
Sam Carrick
Sam Colangelo
Sam Dickinson
Sam Gagner
Sam Lafferty
Sam Malinski
Sam Montembeault
Sam Morton
Sam Poulin
Sam Reinhart
Sam Rinzel
Sam Steel
Sami Aittokallio
Sami Lepisto
Sami Niku
Sami Salo
Sami Vatanen
Sammy Blais
Sammy Walker
Sampo Ranta
Samuel Bolduc
Samuel Ersson
Samuel Fagemo
Samuel Girard
Samuel Helenius
Samuel Henley
Samuel Honzek
Samuel Knazko
Samuel Laberge
Samuel Montembeault
Samuel Morin
Samuel Pahlsson
Samuel Walker
Sandis Vilmanis
Santeri Hatakka
Sasha Chmelevski
Scott Clemmensen
Scott Darling
Scott Foster
Scott Glennie
Scott Gomez
Scott Hannan
Scott Harrington
Scott Hartnell
Scott Jackson
Scott Kosmachuk
Scott Laughton
Scott Lehman
Scott Mayfield
Scott Morrow
Scott Nichol
Scott Niedermayer
Scott Parse
Scott Perunovich
Scott Reedy
Scott Sabourin
Scott Stevens
Scott Timmins
Scott Walker
Scott Wedgewood
Scott Wilson
Scottie Upshall
Scotty Davidson
Seamus Casey
Sean Avery
Sean Bentivoglio
Sean Bergenheim
Sean Collins
Sean Couturier
Sean Day
Sean Durzi
Sean Farrell
Sean Kuraly
Sean Malone
Sean Monahan
Sean O'Donnell
Sean Walker
Sebastian Aho
Sebastian Cossa
Sebastien Caron
Semyon Der-Arguchintsev
Semyon Varlamov
Serge Savard
Sergei Bobrovsky
Sergei Fedorov
Sergei Gonchar
Sergei Kostitsyn
Sergei Murashov
Sergei Plotnikov
Sergei Samsonov
Sergei Shirokov
Sergei Zubov
Sergey Kalinin
Sergey Tolchinsky
Seth Griffith
Seth Helgeson
Seth Jarvis
Seth Jones
Shakir Mukhamadullin
Shane Bowers
Shane Doan
Shane Gersich
Shane Harper
Shane Hnidy
Shane Lachance
Shane O'Brien
Shane Pinto
Shane Prince
Shane Sims
Shane Wright
Shaone Morrisonn
Shaun Heshka
Shawn Belle
Shawn Horcoff
Shawn Hunwick
Shawn Lalonde
Shawn Matthias
Shawn Thornton
Shayne Gostisbehere
Shea Theodore
Shea Weber
Shean Donovan
Sheldon Brookbank
Sheldon Dries
Sheldon Rempal
Sheldon Souray
Shorty Green
Si Griffis
Sid Abel
Sidney Crosby
Simon Benoit
Simon Despres
Simon Edvinsson
Simon Gagne
Simon Holmstrom
Simon Lundmark
Simon Moser
Simon Nemec
Skyler Brind'Amour
Slater Koekkoek
Slava Voynov
Sonny Milano
Spencer Abbott
Spencer Foo
Spencer Knight
Spencer Machacek
Spencer Martin
Spencer Stastney
Sprague Cleghorn
Staffan Kronwall
Stan Mikita
Stanislav Galiev
Stanislav Svozil
Steamer Maxwell
Stefan Della Rovere
Stefan Elliott
Stefan Matteau
Stefan Meyer
Stefan Noesen
Stephane Da Costa
Stephane Robidas
Stephane Veilleux
Stephane Yelle
Stephen Gionta
Stephen Halliday
Stephen Johns
Stephen Weiss
Steve Begin
Steve Bernier
Steve Downie
Steve Eminger
Steve MacIntyre
Steve Mason
Steve Montador
Steve Oleksy
Steve Ott
Steve Regier
Steve Reinprecht
Steve Shutt
Steve Staios
Steve Sullivan
Steve Valiquette
Steve Wagner
Steve Yzerman
Steven Fogarty
Steven Goertzen
Steven Kampfer
Steven Lorentz
Steven Pinizzotto
Steven Santini
Steven Stamkos
Steven Zalewski
Stu Bickel
Stuart Percy
Stuart Skinner
Sven Andrighetto
Sven Baertschi
Sweeney Schriner
Syd Howe
Syl Apps
Sylvio Mantha
T.J. Hensick
T.J. Oshie
T.J. Tynan
TJ Brennan
TJ Brodie
TJ Galiardi
TJ Tynan
Tage Thompson
Tanner Fritz
Tanner Glass
Tanner Jeannot
Tanner Kero
Tanner Laczynski
Tanner Pearson
Tanner Richard
Tarmo Reunanen
Taro Hirose
Taylor Beck
Taylor Chorney
Taylor Fedun
Taylor Hall
Taylor Leier
Taylor Makar
Taylor Pyatt
Taylor Raddysh
Taylor Ward
Ted Kennedy
Ted Lindsay
Teddy Blueger
Teddy Purcell
Teemu Hartikainen
Teemu Laakso
Teemu Pulkkinen
Teemu Selanne
Teppo Numminen
Terry Sawchuk
Teuvo Teravainen
Thatcher Demko
Theo Peckham
Thomas Bordeleau
Thomas Chabot
Thomas Di Pauli
Thomas Greiss
Thomas Harley
Thomas Hickey
Thomas Hodges
Thomas Milic
Thomas Novak
Thomas Pock
Thomas Vanek
Tim Berni
Tim Brent
Tim Conboy
Tim Connolly
Tim Erixon
Tim Gettinger
Tim Gleason
Tim Heed
Tim Horton
Tim Jackman
Tim Kennedy
Tim Schaller
Tim Sestito
Tim Stapleton
Tim Sttzle
Tim Stutzle
Tim Thomas
Tim Wallace
Tim Washe
Timo Meier
Timo Pielmeier
Timothy Gettinger
Timothy Liljegren
Tiny Thompson
Tobias Bjornfot
Tobias Lindberg
Tobias Rieder
Tobias Stephan
Toby Enstrom
Toby Petersen
Todd Bertuzzi
Todd Fedoruk
Todd Marchant
Todd White
Toe Blake
Tom Cavanagh
Tom Gilbert
Tom Hooper
Tom Johnson
Tom Kostopoulos
Tom Kuhnhackl
Tom McCollum
Tom Poti
Tom Preissing
Tom Pyatt
Tom Sestito
Tom Wandell
Tom Willander
Tom Wilson
Tomas Fleischmann
Tomas Hertl
Tomas Holmstrom
Tomas Hyka
Tomas Jurco
Tomas Kaberle
Tomas Kana
Tomas Kopecky
Tomas Kubalik
Tomas Kundratek
Tomas Mojzis
Tomas Nosek
Tomas Plekanec
Tomas Plihal
Tomas Tatar
Tomas Vincour
Tomas Vokoun
Tommy Cross
Tommy Dunderdale
Tommy Novak
Tommy Phillips
Tommy Smith
Tommy Wingels
Toni Lydman
Tony DeAngelo
Tony Esposito
Torey Krug
Torrey Mitchell
Travis Boyd
Travis Dermott
Travis Hamonic
Travis Konecny
Travis Mitchell
Travis Moen
Travis Morin
Travis Sanheim
Travis Turnbull
Travis Zajac
Trent Frederic
Trent Hunter
Trent Miner
Trent Whitfield
Trevor Carrick
Trevor Daley
Trevor Frischmon
Trevor Gillies
Trevor Kuntar
Trevor Lewis
Trevor Moore
Trevor Murphy
Trevor Smith
Trevor Zegras
Trevor van Riemsdyk
Trey Fix-Wolansky
Tristan Broz
Tristan Jarry
Tristan Lennox
Tristan Luneau
Tristen Nielsen
Tristen Robins
Triston Grant
Troy Bodie
Troy Brouwer
Troy Grosenick
Troy Stecher
Troy Terry
Tucker Poolman
Tuomo Ruutu
Turk Broda
Turner Elson
Tuukka Rask
Ty Conklin
Ty Dellandrea
Ty Emberson
Ty Mueller
Ty Murchison
Ty Rattie
Ty Smith
Ty Wishart
Tyce Thompson
Tye Felhaber
Tye Kartye
Tye McGinn
Tyler Angle
Tyler Arnason
Tyler Benson
Tyler Bertuzzi
Tyler Bozak
Tyler Bunz
Tyler Cuma
Tyler Eckford
Tyler Ennis
Tyler Gaudet
Tyler Graovac
Tyler Johnson
Tyler Kennedy
Tyler Kleven
Tyler Lewington
Tyler Motte
Tyler Myers
Tyler Pitlick
Tyler Randell
Tyler Seguin
Tyler Sloan
Tyler Toffoli
Tyler Tucker
Tyler Wotherspoon
Tyrell Goulbourne
Tyson Barrie
Tyson Foerster
Tyson Jost
Tyson Kozak
Tyson Strachan
Ukko-Pekka Luukkonen
Urho Vaakanainen
Uvis Balinskis
Vadim Shipachyov
Valentin Zykov
Valeri Kharlamov
Valeri Nichushkin
Valtteri Filppula
Valtteri Puustinen
Vasily Podkolzin
Vasily Ponomarev
Veini Vehvilainen
Vernon Fiddler
Vesa Toskala
Viacheslav Fetisov
Victor Antipin
Victor Bartley
Victor Ejdsell
Victor Hedman
Victor Mancini
Victor Mete
Victor Olofsson
Victor Oreskovich
Victor Ostman
Victor Rask
Victor Soderstrom
Viktor Arvidsson
Viktor Fasth
Viktor Kozlov
Viktor Lodin
Viktor Loov
Viktor Stalberg
Viktor Svedberg
Viktor Tikhonov
Ville Heinola
Ville Husso
Ville Koistinen
Ville Koivunen
Ville Leino
Ville Ottavainen
Ville Peltonen
Vince Dunn
Vincent Desharnais
Vincent Iorio
Vincent Lecavalier
Vincent Trocheck
Vinni Lettieri
Vinnie Hinostroza
Vinny Prospal
Vitali Kravtsov
Vitaly Abramov
Vitek Vanecek
Vladimir Mihalik
Vladimir Sobotka
Vladimir Tarasenko
Vladimir Tkachev
Vladimir Zharkov
Vladislav Gavrikov
Vladislav Kamenev
Vladislav Kolyachonok
Vladislav Namestnikov
Vladislav Tretiak
Vojtech Mozik
Vyacheslav Buteyets
Vyacheslav Kozlov
Wade Allison
Wade Belak
Wade Brookbank
Wade Dubielewicz
Wade Megan
Wade Redden
Walker Duehr
Waltteri Merela
Warren Foegele
Warren Peters
Wayne Gretzky
Wayne Primeau
Wayne Simmonds
Wes O'Neill
Will Acton
Will Borgen
Will Butcher
Will Cuylle
Will O'Neill
Will Smith
William Bitten
William Borgen
William Carrier
William Dufour
William Eklund
William Karlsson
William Lagesson
William Lockwood
William Nylander
William Stromgren
Willie Mitchell
Wojtek Wolski
Woody Dumart
Wyatt Aamodt
Wyatt Johnston
Wyatt Kaiser
Wyatt Kalynuk
Xavier Bourgault
Xavier Ouellet
Xavier Parent
Yakov Trenin
Yan Kuznetsov
Yan Stastny
Yaniv Perets
Yann Danis
Yann Sauve
Yanni Gourde
Yannick Weber
Yaroslav Askarov
Yegor Chinakhov
Yegor Sharangovich
Yohann Auvitu
Yvan Cournoyer
Zac Dalpe
Zac Jones
Zac Rinaldo
Zach Aston-Reese
Zach Benson
Zach Bogosian
Zach Boychuk
Zach Dean
Zach Fucale
Zach Hamill
Zach Hyman
Zach Metsa
Zach Parise
Zach Redmond
Zach Sanford
Zach Sawchenko
Zach Senyshyn
Zach Sill
Zach Trotman
Zach Werenski
Zach Whitecloud
Zachary Aston-Reese
Zachary Bolduc
Zachary Hayes
Zachary L'Heureux
Zachary Sanford
Zack Bolduc
Zack Kassian
Zack MacEwen
Zack Mitchell
Zack Ostapchuk
Zack Smith
Zack Stortini
Zakhar Bardakov
Zane McIntyre
Zayne Parekh
Zbynek Michalek
Zdeno Chara
Zeev Buium
Zemgus Girgensons
Zenon Konopka
Pipi Caca
ZZZZ Sentinel Test Player
"""

    /// Normalizes a name into a comparison key (lowercased, diacritics removed, letters+spaces only).
    private static func key(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        let normalizedChars = folded.map { ch -> Character in
            (ch.isLetter || ch == " ") ? ch : " "
        }

        return String(normalizedChars)
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let set: Set<String> = {
        Set(raw
            .split(separator: "\n")
            .map(String.init)
            .map { key($0) }
            .filter { !$0.isEmpty }
        )
    }()

    static func isKnown(_ name: String) -> Bool {
        set.contains(key(name))
    }
}


//
//  CVPhotoOCRAddCardView.swift
//  Collectly
//
//  Photo -> OCR Vision (Front) -> Step 2 (Back) -> Merge -> Save
//



// MARK: - Scan Phase (CollX-style camera flow)
fileprivate enum ScanPhase: Equatable {
    case capturingFront
    case flipPrompt
    case capturingBack
    case processing
    case preview
}

// MARK: Helper pour vérifier si un string contient des noms d'équipes
fileprivate func looksLikeTeamName(_ text: String) -> Bool {
    let teamWords = [
        "RANGERS", "CANADIENS", "MAPLE", "LEAFS", "BRUINS", "BLACKHAWKS", 
        "AVALANCHE", "OILERS", "FLAMES", "SENATORS", "JETS", "PANTHERS", 
        "LIGHTNING", "PENGUINS", "CAPITALS", "ISLANDERS", "DEVILS", "KINGS",
        "DUCKS", "SHARKS", "STARS", "WILD", "SABRES", "BLUES", "PREDATORS", 
        "KRAKEN", "HURRICANES", "COYOTES", "GOLDEN", "KNIGHTS"
    ]
    // Nettoyer le texte : enlever apostrophes, guillemets, ponctuation
    let cleaned = text.uppercased()
        .replacingOccurrences(of: "'", with: "")
        .replacingOccurrences(of: "\"", with: "")
        .replacingOccurrences(of: "\u{2019}", with: "")  // curly apostrophe
        .replacingOccurrences(of: "\u{201C}", with: "")  // left double quote
        .replacingOccurrences(of: "\u{201D}", with: "")  // right double quote
    
    return teamWords.contains(where: { cleaned.contains($0) })
}

// MARK: Helper pour valider les numéros de carte préfixés
fileprivate func isValidPrefixedCardNumber(_ cardNumber: String) -> Bool {
    guard cardNumber.contains("-") else { return false }
    
    // Préfixes invalides (mots OCR mal interprétés)
    let invalidPrefixes = ["WEG-", "IES-", "THE-", "AND-", "FOR-", "WITH-", "JUST-"]
    let upper = cardNumber.uppercased()
    
    for prefix in invalidPrefixes {
        if upper.hasPrefix(prefix) {
            return false
        }
    }
    
    return true
}

// MARK: Photo â†’ OCR (Vision) â†’ Ajout (Front + Back)

struct CVPhotoOCRAddCardView: View {

    // MARK: - Scan Phase State
    @State private var scanPhase: ScanPhase = .capturingFront
    @State private var showFlipAnimation: Bool = false
    @State private var processingProgress: String = ""

    // === eBay Debug State (auto-added) ===
    @State private var ebayDebugIsUsingProxy: Bool? = nil
    @State private var ebayDebugHttpStatusCode: Int? = nil
    @State private var ebayDebugUrl: String? = nil
    @State private var ebayDebugResponseBody: String = ""
    @State private var ebayDebugLastQuery: String = ""
    @State private var ebayDebugLastTriedQueries: [String] = []
    @State private var playerNameLockEnabled: Bool = true
    @State private var isMVPCard: Bool = false  // Détecté depuis le verso


    let ownerId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // Prevent unwanted auto-dismiss
    @State private var allowDismiss: Bool = false

    // Picker
    private enum PickerRoute: Identifiable {
        case cameraFront
        case libraryFront
        case cameraBack
        case libraryBack

        var id: Int {
            switch self {
            case .cameraFront: return 1
            case .libraryFront: return 2
            case .cameraBack: return 3
            case .libraryBack: return 4
            }
        }

        var sourceType: UIImagePickerController.SourceType {
            switch self {
            case .cameraFront, .cameraBack: return .camera
            case .libraryFront, .libraryBack: return .photoLibrary
            }
        }

        var isFront: Bool {
            switch self {
            case .cameraFront, .libraryFront: return true
            case .cameraBack, .libraryBack: return false
            }
        }
    }

    @State private var activePicker: PickerRoute? = nil

    // Images
    @State private var frontUIImage: UIImage? = nil
    @State private var backUIImage: UIImage? = nil
    @State private var frontImageData: Data? = nil
    @State private var backImageData: Data? = nil

    // OCR
    @State private var isWorking = false
    @State private var frontLines: [String] = []
    @State private var backLines: [String] = []

    @State private var frontRawLines: [String] = []
    @State private var backRawLines: [String] = []
    
    // 🛡️ Numéro détecté par OCR du dos - PROTECTION ABSOLUE contre override DB
    @State private var ocrBackCardNumber: String = ""
    
    // 📤 Firebase Upload
    @State private var isUploadingToFirebase = false
    @State private var firebaseUploadStatus = ""

    // âœ… Allow cancelling/serializing OCR work to avoid UI freezes
    @State private var frontOCRTask: Task<Void, Never>? = nil
    @State private var backOCRTask: Task<Void, Never>? = nil
    
    // eBay Image Search
    @State private var isImageSearching = false
    @State private var imageSearchStatus = ""

    // Fields
    @State private var playerName: String = ""
    @State private var playerNameRefreshID = UUID() // Pour forcer le refresh du TextField
    @State private var cardYear: String = ""
    @State private var companyName: String = ""
    @State private var setName: String = ""
    @State private var cardNumber: String = ""

    // OCR name lock (front + back)
    @State private var frontFullNameDetected: String? = nil
    @State private var backFullNameDetected: String? = nil
    @State private var lockedPlayerName: String? = nil


    // MARK: - Card number quality / override rules

    /// Returns a score for how "credible" a card-number candidate is.
    /// Higher = better.
    private func cardNumberScore(_ s: String) -> Int {
        let up = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if up.isEmpty { return 0 }

        // Explicit "#123"
        if up.hasPrefix("#") {
            let digits = up.filter { $0.isNumber }
            if let v = Int(digits), v > 0, v < 5000 { return 85 }
            return 60
        }

        // Alphanumeric code like "TS-30", "CQ-8", "FWA-3"
        if up.range(of: #"^[A-Z]{1,4}-\d{1,4}$"#, options: String.CompareOptions.regularExpression) != nil {
            let parts = up.split(separator: "-").map(String.init)
            let prefix = parts.first ?? ""
            let digits = parts.last ?? ""
            var score = 70
            score += min(prefix.count, 4) * 5  // prefer longer prefix
            score += min(digits.count, 4) * 2

            // Prefer known insert prefixes (helps "TS-30" win over random noise)
            if prefix == "TS" { score += 25 }
            if prefix == "YG" { score += 10 }

            // Penalize single-letter prefixes (often OCR/stat noise). Keep Encore as exception.
            if prefix.count == 1 && prefix != "E" { score -= 20 }

            // Penalize 4-digit "codes" that look like years
            if digits.count == 4, let y = Int(digits), (1900...2099).contains(y) { score -= 30 }

            return max(0, score)
        }

        // Anything else
        return 10
    }

    private func isWeakCardNumber(_ s: String) -> Bool {
        cardNumberScore(s) < 70
    }

    /// Merge rule: allow a later OCR pass (often BACK) to override a weaker earlier value (often FRONT).
    private func mergeCardNumber(current: String, incoming: String) -> String {
        let cur = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let inc = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if cur.isEmpty { return inc }
        if inc.isEmpty { return cur }

        let curScore = cardNumberScore(cur)
        let incScore = cardNumberScore(inc)

        // Override only if incoming is clearly better (or current is weak and incoming isn't).
        if (isWeakCardNumber(cur) && !isWeakCardNumber(inc)) || (incScore >= curScore + 10) {
            return inc
        }
        return cur
    }

    // Debug
    @State private var showDebug = true
    @State private var ebayNameCandidate: String = ""
    @State private var ebayNameConfidence: Double? = nil
    @State private var ebayNameTitle: String = ""
    @State private var ocrNameForComparison: String = ""

    // Save error UI
    @State private var showSaveErrorAlert: Bool = false
    @State private var saveErrorMessage: String? = nil



    // eBay debug (requÃªte + rÃ©sultats)
    @State private var ebayDebugQuery: String = ""
    @State private var ebayDebugStatus: String = ""
    @State private var ebayDebugTitles: [String] = []
    @State private var ebayDebugLastUpdated: Date? = nil

    @State private var ebayDebugLastQueries: [String] = []
    @State private var ebayDebugHttpStatus: Int? = nil
    @State private var ebayDebugUsedUrl: String = ""
    @State private var ebayDebugBodyPreview: String = ""
    @State private var ebayDebugErrorMessage: String = ""
    @State private var ebayDebugSource: String = ""
    private var canSave: Bool {
        !playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || frontImageData != nil || backImageData != nil
    }



    // MARK: eBay configuration

    private static func isEbayConfigured() -> Bool {
        // For the Finding API "findCompletedItems", only the AppID / ClientID is required.
        let appID = ((Bundle.main.object(forInfoDictionaryKey: "EBAY_APP_ID") as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID = ((Bundle.main.object(forInfoDictionaryKey: "EBAY_CLIENT_ID") as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !appID.isEmpty || !clientID.isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            switch scanPhase {
            case .capturingFront:
                cameraPhaseView(isFront: true)
                
            case .flipPrompt:
                flipPromptView
                
            case .capturingBack:
                cameraPhaseView(isFront: false)
                
            case .processing:
                processingPhaseView
                
            case .preview:
                previewPhaseView
            }
            
            // 🔧 DEBUG: Bouton flottant pour voir les images
            VStack {
                HStack {
                    Spacer()
                    Button {
                        showDebugInfo()
                    } label: {
                        Image(systemName: "photo.stack")
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.blue.opacity(0.7))
                            .clipShape(Circle())
                    }
                    .padding()
                }
                Spacer()
            }
        }
        .alert("Impossible d'enregistrer", isPresented: $showSaveErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(saveErrorMessage ?? "Erreur inconnue")
        }
    }
    
    // MARK: - Debug Info
    
    private func showDebugInfo() {
        // DÉSACTIVÉ: ReferenceImageStore supprimé
        print("📊 Debug info disabled (ReferenceImageStore removed)")
        // let count = ReferenceImageStore.shared.getReferenceImageCount()
        // let images = ReferenceImageStore.shared.getAllReferenceImages()
        // let path = ReferenceImageStore.shared.debugPath()
    }
    
    // MARK: - Camera Phase View
    
    @ViewBuilder
    private func cameraPhaseView(isFront: Bool) -> some View {
        ZStack {
            CardScanCameraPreview { image in
                if isFront {
                    handleFrontCapture(image)
                } else {
                    handleBackCapture(image)
                }
            }
            .ignoresSafeArea()
            
            VStack {
                // Top bar
                HStack {
                    Button {
                        allowDismiss = true
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    
                    Spacer()
                    
                    Text(isFront ? "AVANT" : "DOS")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                    
                    Spacer()
                    
                    // Placeholder for balance
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                // Simple rectangle guide for VERTICAL card - LARGE guide
                GeometryReader { geo in
                    let guideWidth = geo.size.width * 0.85  // 85% de la largeur (LARGE!)
                    let guideHeight = guideWidth * 1.4  // Ratio carte hockey (vertical)
                    
                    // Descendre de 125px pour centrer visuellement
                    let yOffset: CGFloat = 125
                    
                    Rectangle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: guideWidth, height: guideHeight)
                        .position(x: geo.size.width / 2, y: (geo.size.height / 2) + yOffset)
                }
                
                // Instructions at top
                VStack {
                    Text(isFront ? "REMPLIS TOUT LE CADRE" : "RETOURNE ET REMPLIS LE CADRE")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(.top, 60)
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Flip Prompt View
    
    private var flipPromptView: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // Card flip animation
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 180, height: 250)
                    .overlay(
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 50))
                            .foregroundColor(.white)
                    )
            }
            .rotation3DEffect(
                .degrees(showFlipAnimation ? 180 : 0),
                axis: (x: 0, y: 1, z: 0)
            )
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: showFlipAnimation)
            
            Text("Retourne la carte")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("Le dos contient souvent le nom, l'année et le numéro")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
            
            HStack(spacing: 20) {
                Button {
                    // Skip back scan
                    scanPhase = .processing
                    Task { await processImages() }
                } label: {
                    Text("Passer")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 30)
                        .padding(.vertical, 14)
                        .background(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 1))
                }
                
                Button {
                    scanPhase = .capturingBack
                } label: {
                    Text("Continuer")
                        .font(.headline)
                        .foregroundColor(.black)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Color.white))
                }
            }
            .padding(.bottom, 50)
        }
        .onAppear {
            showFlipAnimation = true
        }
    }
    
    // MARK: - Processing Phase View
    
    private var processingPhaseView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            
            Text(processingProgress.isEmpty ? "Analyse en cours..." : processingProgress)
                .font(.headline)
                .foregroundColor(.white)
        }
    }
    
    // MARK: - Preview Phase View
    
    private var previewPhaseView: some View {
        NavigationStack {
            Form {
                // Images - LARGE size for better visibility
                Section("Photos") {
                    HStack(spacing: 16) {
                        if let front = frontUIImage {
                            VStack(spacing: 6) {
                                Image(uiImage: front)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 400)
                                    .cornerRadius(12)
                                    .shadow(radius: 3)
                                Text("Avant")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        if let back = backUIImage {
                            VStack(spacing: 6) {
                                Image(uiImage: back)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 400)
                                    .cornerRadius(12)
                                    .shadow(radius: 3)
                                Text("Arrière")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 16)
                }
                
                // Detected info
                Section("Infos détectées") {
                    TextField("Nom du joueur", text: $playerName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(true)
                        .onSubmit {
                            // Auto-normaliser: "DUSTIN WOLF" → "Dustin Wolf"
                            playerName = playerName.properCapitalized()
                        }
                    TextField("Année (ex: 2023-24)", text: $cardYear)
                    TextField("Compagnie", text: $companyName)
                    TextField("Set", text: $setName)
                    TextField("Numéro", text: $cardNumber)
                        .onChange(of: cardNumber) { _, newValue in
                            // Auto-enlever le # du numéro
                            let cleaned = cleanCardNumber(newValue)
                            if cleaned != newValue {
                                cardNumber = cleaned
                            }
                        }
                }
                
                // Actions
                Section {
                    Button {
                        save()
                    } label: {
                        Label("Enregistrer", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(!canSave || isWorking)
                }
                
                Section {
                    Button {
                        retakeScan()
                    } label: {
                        Label("Reprendre le scan", systemImage: "arrow.counterclockwise")
                    }
                    
                    Button("Fermer", role: .cancel) {
                        allowDismiss = true
                        dismiss()
                    }
                }
                
                // Debug
                if showDebug {
                    Section("Debug OCR (avant)") {
                        if frontLines.isEmpty {
                            Text("—").foregroundStyle(.secondary)
                        } else {
                            ForEach(frontLines.prefix(10), id: \.self) { Text("• \($0)").font(.caption) }
                        }
                    }
                    Section("Debug OCR (dos)") {
                        if backLines.isEmpty {
                            Text("—").foregroundStyle(.secondary)
                        } else {
                            ForEach(backLines.prefix(10), id: \.self) { Text("• \($0)").font(.caption) }
                        }
                    }
                }
                
                Section {
                    Toggle("Debug OCR", isOn: $showDebug)
                }
            }
            .navigationTitle("Vérifier")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: - Capture Handlers
    
    private func handleFrontCapture(_ image: UIImage) {
        // Crop aggressively to remove background
        print("📸 FRONT CAPTURE - Original size: \(image.size.width) x \(image.size.height)")
        Task {
            let cropped = aggressiveCenterCrop(image, cropPercent: 0.20) // Enlever 20% de chaque côté
            print("📸 FRONT CROPPED - Size: \(cropped.size.width) x \(cropped.size.height)")
            
            // Resize pour réduire poids (max 1000px de hauteur)
            let resized = resizeToMaxHeight(cropped, maxHeight: 1000)
            print("📸 FRONT RESIZED - Size: \(resized.size.width) x \(resized.size.height)")
            
            await MainActor.run {
                frontUIImage = resized
                frontImageData = resized.jpegData(compressionQuality: 0.60) // 60% qualité
                scanPhase = .flipPrompt
            }
        }
    }
    
    private func handleBackCapture(_ image: UIImage) {
        // Crop aggressively to remove background
        print("📸 BACK CAPTURE - Original size: \(image.size.width) x \(image.size.height)")
        Task {
            let cropped = aggressiveCenterCrop(image, cropPercent: 0.20) // Enlever 20% de chaque côté
            print("📸 BACK CROPPED - Size: \(cropped.size.width) x \(cropped.size.height)")
            
            // Resize pour réduire poids (max 1000px de hauteur)
            let resized = resizeToMaxHeight(cropped, maxHeight: 1000)
            print("📸 BACK RESIZED - Size: \(resized.size.width) x \(resized.size.height)")
            
            await MainActor.run {
                backUIImage = resized
                backImageData = resized.jpegData(compressionQuality: 0.60) // 60% qualité
                scanPhase = .processing
            }
            await processImages()
        }
    }
    
    // Aggressive center crop - remove X% from each edge
    private func aggressiveCenterCrop(_ image: UIImage, cropPercent: CGFloat) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        
        // Calculate crop amount
        let cropX = width * cropPercent
        let cropY = height * cropPercent
        
        let cropRect = CGRect(
            x: cropX,
            y: cropY,
            width: width - (cropX * 2),
            height: height - (cropY * 2)
        )
        
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return image }
        
        return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
    }
    
    // Resize to max height while maintaining aspect ratio
    private func resizeToMaxHeight(_ image: UIImage, maxHeight: CGFloat) -> UIImage {
        let height = image.size.height
        
        // Si déjà plus petite, ne pas agrandir
        if height <= maxHeight {
            return image
        }
        
        let ratio = maxHeight / height
        let newWidth = image.size.width * ratio
        let newSize = CGSize(width: newWidth, height: maxHeight)
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    
    // Normaliser l'orientation de l'image pour éviter les problèmes d'affichage
    private func normalizeImageOrientation(_ image: UIImage) -> UIImage {
        // Si l'image est déjà en .up, pas besoin de normaliser
        guard image.imageOrientation != .up else { 
            // Même si orientation correcte, redimensionner pour uniformité
            return resizeImageForDisplay(image)
        }
        
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return resizeImageForDisplay(normalized ?? image)
    }
    
    // Redimensionner l'image à une taille standard pour affichage uniforme
    private func resizeImageForDisplay(_ image: UIImage) -> UIImage {
        // NO crop - keep full image with background
        print("🔧 RESIZE - Input size: \(image.size.width) x \(image.size.height)")
        
        // Redimensionner proportionnellement pour économiser mémoire
        let maxDimension: CGFloat = 1200  // Augmenté pour garder qualité
        let ratio = image.size.width / image.size.height
        
        var newSize: CGSize
        if ratio > 1 {
            // Paysage
            newSize = CGSize(width: maxDimension, height: maxDimension / ratio)
        } else {
            // Portrait
            newSize = CGSize(width: maxDimension * ratio, height: maxDimension)
        }
        
        print("🔧 RESIZE - Output size: \(newSize.width) x \(newSize.height), ratio: \(ratio)")
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        
        return resized
    }
    
    // Cropper automatiquement les bords vides/blancs autour du contenu
    private func cropToContent(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        
        let width = cgImage.width
        let height = cgImage.height
        
        // AGGRESSIVE CENTER CROP - garder 70% du centre (crop 15% de chaque côté)
        let cropPercent: CGFloat = 0.15
        let cropX = Int(CGFloat(width) * cropPercent)
        let cropY = Int(CGFloat(height) * cropPercent)
        let cropWidth = width - (cropX * 2)
        let cropHeight = height - (cropY * 2)
        
        print("📐 AGGRESSIVE CROP: \(width)x\(height) → \(cropWidth)x\(cropHeight)")
        
        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
        
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return image }
        
        return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
    }
    
    // MARK: - Process Images
    
    // Helper: Nettoyer le numéro de carte (enlever #, espaces, etc.)
    private func cleanCardNumber(_ number: String) -> String {
        return number
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
    
    @MainActor
    private func processImages() async {
        isWorking = true
        isMVPCard = false  // Reset pour chaque nouveau scan
        // 🎯 PROGRESSIVE VISION: DÉSACTIVÉ (ReferenceImageStore supprimé)
        // if let frontImage = frontUIImage {
        //     let refCount = ReferenceImageStore.shared.getReferenceImageCount()
        //     print("📚 Images de référence disponibles: \(refCount)")
        // }
        
        print("✅ Vision matching skipped (disabled), continuing with OCR...")
        
        // Process FRONT
        if let front = frontUIImage {
            processingProgress = "Analyse de l'avant..."
            let result = await Task.detached(priority: .userInitiated) { () -> (raw: [String], clean: [String], parsed: FrontOCRParser.FrontResult?) in
                let rawLines = await OCR.runMultiPass(on: front, note: "front")
                let cleanLines = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                let parsed = await MainActor.run { FrontOCRParser.parse(lines: cleanLines) }
                return (rawLines, cleanLines, parsed)
            }.value
            
            frontRawLines = result.raw
            frontLines = result.clean
            
            // 🎯 DÉTECTION MVP ROOKIES: Si "ROOKIES" apparaît sur le recto, c'est MVP
            let frontTextUpper = frontLines.joined(separator: " ").uppercased()
            if frontTextUpper.contains("ROOKIES") {
                print("🎯 ROOKIES detected on front - this is MVP card")
                isMVPCard = true
                if !setName.uppercased().contains("MVP") {
                    setName = "MVP"
                }
            }
            
            // 🎯 DÉTECTION YOUNG GUNS: Si "YOUNGGUNS" apparaît sur le recto
            if frontTextUpper.contains("YOUNGGUNS") || frontTextUpper.contains("YOUNG GUNS") {
                print("🎯 YOUNGGUNS detected on front - protecting player name")
                if !setName.uppercased().contains("YOUNG GUNS") {
                    setName = "Young Guns"
                }
                
                // 🔒 Lock le nom du joueur si détecté
                if !playerName.isEmpty && !playerNameLockEnabled {
                    let detectedName = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if KnownPlayerNames.isKnown(detectedName) || KnownPlayers.canonicalize(detectedName) != nil {
                        print("🏆 YOUNG GUNS PRIORITY LOCK: [\(detectedName)] - front name is reliable")
                        lockedPlayerName = detectedName
                        playerNameLockEnabled = true
                    }
                }
            }
            
            if let parsed = result.parsed {
                if let y = parsed.year, !y.isEmpty { cardYear = normalizeYear(y) }
                if companyName.isEmpty, let b = parsed.company { companyName = b }
                if let s = parsed.setName, !s.isEmpty {
                    if setName.isEmpty { setName = s }
                }
                if let frontNum = parsed.cardNumber, !frontNum.isEmpty {
                    let up = frontNum.uppercased()
                    let specialPrefixes = ["PC-", "SR-", "TS-", "FWA-", "CQ-", "CC-", "AC-", "HC-"]
                    if specialPrefixes.contains(where: { up.hasPrefix($0) }) {
                        cardNumber = frontNum
                    }
                }
                if let p = parsed.fullName, !p.isEmpty, !playerNameLockEnabled {
                    // 🚫 FILTRER "Young Guns" - ce n'est pas un nom de joueur
                    let upper = p.uppercased()
                    let isYoungGuns = upper.contains("YOUNG") || upper.contains("GUNS") || 
                                      upper.contains("ROOKIES") || upper == "YOUNGGUNS"
                    
                    if !isYoungGuns && (playerName.isEmpty || looksLikeBadName(playerName)) {
                        if let canonical = KnownPlayers.canonicalize(p) {
                            playerName = normalizePlayerNameDisplay(canonical)
                        } else {
                            playerName = normalizePlayerNameDisplay(p)
                        }
                    }
                }
            }
        }
        
        // Process BACK
        if let back = backUIImage {
            processingProgress = "Analyse du dos..."
            let result = await Task.detached(priority: .userInitiated) { () -> (raw: [String], clean: [String], parsed: BackOCRParser.Result) in
                let rawLines = await OCR.runMultiPass(on: back, note: "back")
                let cleanLines = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                let parsed = await MainActor.run { BackOCRParser.parse(lines: cleanLines, companyHint: nil) }
                return (rawLines, cleanLines, parsed)
            }.value
            
            backRawLines = result.raw
            backLines = result.clean
            
            let parsed = result.parsed
            
            // Year: back wins
            if let y = parsed.year, !y.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cardYear = normalizeYear(y.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            
            // Company: back wins
            if let c = parsed.company, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if companyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    companyName = c.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            
            // Set: back wins
            if let s = parsed.setName, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let incoming = s.trimmingCharacters(in: .whitespacesAndNewlines)
                let current = setName.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if current.isEmpty {
                    setName = incoming
                } else {
                    let cur = current.uppercased()
                    let inc = incoming.uppercased()
                    
                    // Toujours préférer le dos si :
                    // 1. C'est Future Watch ou MVP (sets clairs sur le dos)
                    // 2. Le front contient du garbage (symboles, mots étranges, ou très court)
                    let backIsSpecialSet = inc.contains("FUTURE WATCH") || inc.contains("MVP")
                    let frontIsGarbage = current.contains("«") || current.contains("»") || 
                                        current.contains("Redemption") || current.contains("Cards Ie") ||
                                        current.contains(".") || current.contains(",") ||
                                        current.count <= 4  // Ex: ". E.c.k" = 6 chars mais quasi vide
                    
                    if (backIsSpecialSet && !cur.contains(inc)) || frontIsGarbage {
                        setName = incoming
                    }
                }
            }
            
            // 🎯 DÉTECTION MVP FORCÉE: Si les lignes du dos contiennent "MVP" + "HOCKEY", forcer setName = "MVP"
            // Même si le parser n'a pas capturé "MVP" correctement
            let backTextUpper = backLines.joined(separator: " ").uppercased()
            if (backTextUpper.contains("MVP") && backTextUpper.contains("HOCKEY")) || 
               (backTextUpper.contains("MVP") && backTextUpper.contains("UPPER DECK")) {
                if !setName.uppercased().contains("MVP") {
                    setName = "MVP"
                    print("🎯 Forced MVP detection from back OCR raw lines")
                }
                // 🔒 Activer le flag MVP pour protection totale
                isMVPCard = true
                print("🔒 MVP card detected - full protection activated")
            }
            
            // Card number: back is truth
            if let n = parsed.cardNumber, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let candidate = n.trimmingCharacters(in: .whitespacesAndNewlines)
                
                print("🛡️ OCR back detected card number: [\(candidate)]")
                
                // 🎯 Pour MVP, valider d'abord contre la base de données
                if isMVPCard {
                    // Valider si ce numéro existe dans TCDB pour ce joueur/set
                    let validationResult = findCardByNumber(
                        cardNumber: candidate,
                        setName: setName.isEmpty ? "MVP" : setName,
                        year: cardYear.isEmpty ? nil : cardYear,
                        playerName: playerName.isEmpty ? nil : playerName
                    )
                    
                    if validationResult != nil {
                        // ✅ Numéro valide dans la base de données
                        print("🎯 MVP: Forcing back number [\(candidate)] over current [\(cardNumber)] (validated in DB)")
                        cardNumber = cleanCardNumber(candidate)
                        ocrBackCardNumber = cleanCardNumber(candidate)  // Protéger seulement si valide
                        print("🛡️ OCR back number PROTECTED: [\(cardNumber)]")
                    } else {
                        // ❌ Numéro invalide - probablement du texte mal lu
                        print("⚠️ MVP: Rejecting back number [\(candidate)] - not found in database for [\(playerName)] [\(setName)] [\(cardYear)]")
                        print("   Keeping current number: [\(cardNumber)]")
                        // Ne PAS remplir ocrBackCardNumber pour éviter override plus tard
                    }
                } else {
                    // Pour non-MVP, protéger le numéro du dos
                    ocrBackCardNumber = cleanCardNumber(candidate)
                    print("🛡️ OCR back number PROTECTED: [\(ocrBackCardNumber)]")
                    cardNumber = mergeCardNumber(current: cardNumber, incoming: cleanCardNumber(candidate))
                }
                
                // 🔧 AUTO-CORRECTION: Si le numéro a un préfixe de subset mais le set est générique,
                // corriger le set automatiquement
                let numUpper = cardNumber.uppercased()
                if numUpper.hasPrefix("DZ-") && !setName.uppercased().contains("DAZZLERS") {
                    print("🔧 Auto-correcting set: [\(setName)] → [Dazzlers] based on card number [\(cardNumber)]")
                    setName = "Dazzlers"
                } else if numUpper.hasPrefix("PC-") && !setName.uppercased().contains("POPULATION") {
                    print("🔧 Auto-correcting set: [\(setName)] → [Population Count] based on card number [\(cardNumber)]")
                    setName = "Population Count"
                } else if numUpper.hasPrefix("CQ-") && !setName.uppercased().contains("CUP") && !setName.uppercased().contains("QUEST") {
                    print("🔧 Auto-correcting set: [\(setName)] → [Cup Quest] based on card number [\(cardNumber)]")
                    setName = "Cup Quest"
                } else if numUpper.hasPrefix("SR-") && !setName.uppercased().contains("SIZZLE") && !setName.uppercased().contains("REEL") {
                    print("🔧 Auto-correcting set: [\(setName)] → [Sizzle Reel] based on card number [\(cardNumber)]")
                    setName = "Sizzle Reel"
                } else if numUpper.hasPrefix("FW-") && !setName.uppercased().contains("FUTURE") && !setName.uppercased().contains("WATCH") {
                    print("🔧 Auto-correcting set: [\(setName)] → [Future Watch] based on card number [\(cardNumber)]")
                    setName = "Future Watch"
                }
            }
            
            // Player name: back can override bad OCR
            if let p = parsed.fullName, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !playerNameLockEnabled {
                let incoming = p.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // 🚫 FILTRER "Young Guns" - ce n'est pas un nom de joueur
                let incomingUpper = incoming.uppercased()
                let isYoungGuns = incomingUpper.contains("YOUNG") || incomingUpper.contains("GUNS") || 
                                  incomingUpper.contains("ROOKIES") || incomingUpper == "YOUNGGUNS"
                
                if !isYoungGuns {
                    let currentName = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // ⚠️ VALIDATION: Ne remplacer que si le dos apporte un meilleur nom
                    let backNameIsValid = KnownPlayerNames.isKnown(incoming) || KnownPlayers.canonicalize(incoming) != nil
                    let frontNameIsValid = KnownPlayerNames.isKnown(currentName) || KnownPlayers.canonicalize(currentName) != nil
                    let namesAreDifferent = currentName.uppercased() != incomingUpper
                    
                    // Si le front a un nom complet valide (ex: "SEBASTIAN AHO") et le dos a juste un fragment (ex: "Aho"),
                    // garder le front. Ne remplacer que si le dos est clairement meilleur.
                    let backIsBetter = incoming.count > currentName.count  // Dos plus long
                    let frontIsBad = currentName.isEmpty || looksLikeBadName(playerName) || !frontNameIsValid
                    
                    let shouldReplace = frontIsBad
                        || (backNameIsValid && namesAreDifferent && backIsBetter)  // Dos meilleur seulement s'il est plus long
                        || (backNameIsValid && !frontNameIsValid)  // Dos valide, front invalide
                    
                    if shouldReplace {
                        print("🔄 Replacing front name [\(currentName)] with back name [\(incoming)]")
                        if let canonical = KnownPlayers.canonicalize(incoming) {
                            playerName = normalizePlayerNameDisplay(canonical)
                        } else {
                            playerName = normalizePlayerNameDisplay(incoming)
                        }
                    }
                }
            }
            
            enforcePlayerNameGuardrails()
            recomputePlayerNameLock()
            
            // 🔄 RE-VALIDATION: Si l'année du verso est différente de celle du vision matching,
            // re-chercher dans TCDB avec la nouvelle année
            if !cardNumber.isEmpty && !cardYear.isEmpty && !setName.isEmpty {
                // Re-chercher dans TCDB avec l'année du verso
                if let tcdbResult = findCardByNumber(
                    cardNumber: cardNumber,
                    setName: setName,
                    year: cardYear,
                    playerName: playerName  // Ajouter le nom du joueur pour fallback
                ) {
                    // Mettre à jour le joueur si trouvé
                    if let player = tcdbResult.player, !player.isEmpty {
                        playerName = normalizePlayerNameDisplay(player)
                        print("🔄 Re-validation TCDB avec année du verso: [\(playerName)]")
                    }
                    // Mettre à jour le set complet si trouvé
                    if let fullSetName = tcdbResult.fullSetName {
                        // Formater le nom du set (enlever année + "Upper Deck")
                        setName = formatSetName(fullSetName)
                        
                        // Extraire l'année
                        let parts = fullSetName.split(separator: " ")
                        if let firstPart = parts.first, firstPart.contains("-") {
                            cardYear = String(firstPart)
                        }
                        print("🔄 Set complet mis à jour: \(fullSetName) → formaté: \(setName)")
                    }
                    // Mettre à jour la compagnie
                    if let brand = tcdbResult.brand, !brand.isEmpty {
                        companyName = brand
                    }
                }
            }
            
            // 🎯 MVP PRIORITY LOCK: Pour le set MVP, les infos OCR sont TOUJOURS correctes
            // Lock le nom, le numéro ET le set avant eBay
            if isMVPCard && !playerName.isEmpty && !playerNameLockEnabled {
                let detectedName = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
                if KnownPlayerNames.isKnown(detectedName) || KnownPlayers.canonicalize(detectedName) != nil {
                    print("🏆 MVP PRIORITY LOCK: [\(detectedName)] - MVP OCR is always reliable")
                    lockedPlayerName = detectedName
                    playerNameLockEnabled = true
                    
                    // 🎯 STRATÉGIE MVP: Si on a joueur + année, trouver le numéro dans TCDB
                    if !cardYear.isEmpty {
                        // Cas 1: On a déjà un numéro - le valider
                        if !cardNumber.isEmpty {
                            if let localCard = findCardByNumber(
                                cardNumber: cardNumber,
                                setName: "MVP",
                                year: cardYear,
                                playerName: detectedName  // Ajouter le nom du joueur pour fallback
                            ) {
                                if let foundPlayer = localCard.player, !foundPlayer.isEmpty {
                                    let match = foundPlayer.uppercased() == detectedName.uppercased()
                                    if match {
                                        print("✅ MVP card number [\(cardNumber)] matches player [\(detectedName)]")
                                        print("🔒 Locking card number [\(cardNumber)] and set [MVP]")
                                    } else {
                                        print("⚠️ MVP card number [\(cardNumber)] is for [\(foundPlayer)], not [\(detectedName)]")
                                        print("🔍 Searching by player name instead...")
                                        // Chercher par nom
                                        if let cardByName = findCardInLocalDatabase(
                                            playerName: detectedName,
                                            setName: "MVP",
                                            year: cardYear,
                                            detectedCardNumber: nil
                                        ), let correctNumber = cardByName.number {
                                            cardNumber = correctNumber
                                            print("✅ Found correct MVP number by name: [\(correctNumber)]")
                                        }
                                    }
                                }
                            } else {
                                print("⚠️ Card number [\(cardNumber)] not found in MVP")
                                print("🔍 Searching by player name instead...")
                                // Chercher par nom
                                if let cardByName = findCardInLocalDatabase(
                                    playerName: detectedName,
                                    setName: "MVP",
                                    year: cardYear,
                                    detectedCardNumber: nil
                                ), let correctNumber = cardByName.number {
                                    cardNumber = correctNumber
                                    print("✅ Found MVP number by name: [\(correctNumber)]")
                                }
                            }
                        } else {
                            // Cas 2: Pas de numéro détecté - chercher par nom
                            print("🔍 No card number detected, searching MVP by player name...")
                            if let cardByName = findCardInLocalDatabase(
                                playerName: detectedName,
                                setName: "MVP",
                                year: cardYear,
                                detectedCardNumber: nil
                            ), let correctNumber = cardByName.number {
                                cardNumber = correctNumber
                                print("✅ Found MVP card: [\(detectedName)] = #[\(correctNumber)]")
                            } else {
                                print("⚠️ Player [\(detectedName)] not found in MVP [\(cardYear)]")
                            }
                        }
                    }
                }
            }
            
            // 🎯 PROTECTION: Si on a un nom de joueur valide détecté par l'OCR du dos
            // mais PAS de numéro préfixé valide, chercher dans la base locale par nom
            // pour éviter qu'eBay écrase avec un mauvais numéro
            // ⚠️ SKIP si MVP PRIORITY LOCK est déjà activé (pour éviter de trouver le mauvais set)
            let hasValidPrefixedNumber = isValidPrefixedCardNumber(cardNumber)
            
            if !playerName.isEmpty && !hasValidPrefixedNumber && !setName.isEmpty && !cardYear.isEmpty && !playerNameLockEnabled {
                let detectedName = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
                if KnownPlayerNames.isKnown(detectedName) || KnownPlayers.canonicalize(detectedName) != nil {
                    print("🎯 Valid player name detected in OCR: [\(detectedName)], searching local database to lock info...")
                    
                    // ⚠️ VALIDATION: Si le setName contient des noms d'équipes, l'ignorer
                    // Ex: "HURRICANES I C" n'est pas un vrai set, c'est l'équipe
                    let setNameToUse: String?
                    if looksLikeTeamName(setName) {
                        print("⚠️ setName [\(setName)] contains team name, ignoring for search")
                        setNameToUse = nil  // Chercher dans tous les sets
                    } else {
                        setNameToUse = setName
                    }
                    
                    if let localCard = findCardInLocalDatabase(
                        playerName: detectedName,
                        setName: setNameToUse,
                        year: cardYear
                    ) {
                        if let foundNumber = localCard.number, !foundNumber.isEmpty {
                            // ⚠️ VALIDATION: Si l'OCR a détecté un cardNumber différent,
                            // vérifier que ce combo joueur+numéro existe vraiment
                            let ocrHasNumber = !cardNumber.isEmpty
                            let numbersMatch = cardNumber == foundNumber
                            var shouldLock = true
                            
                            if ocrHasNumber && !numbersMatch {
                                // Vérifier si joueur + OCR number existe dans la base
                                if let cardByNumber = findCardByNumber(
                                    cardNumber: cardNumber,
                                    setName: setNameToUse,
                                    year: cardYear,
                                    playerName: detectedName  // Ajouter le nom du joueur pour fallback
                                ) {
                                    if let playerByNumber = cardByNumber.player, !playerByNumber.isEmpty {
                                        let playerMatch = playerByNumber.uppercased() == detectedName.uppercased()
                                        if !playerMatch {
                                            print("⚠️ OCR mismatch: [\(detectedName)] + [\(cardNumber)] don't match in database")
                                            print("   Database has: [\(playerByNumber)] for number [\(cardNumber)]")
                                            print("   Skipping PRE-LOCK to let eBay correct")
                                            shouldLock = false
                                        }
                                    }
                                }
                            }
                            
                            if shouldLock {
                                print("✅ PRE-LOCK: Found [\(detectedName)] → [\(foundNumber)] in local database")
                                cardNumber = foundNumber
                                
                                // Verrouiller pour empêcher eBay d'écraser
                                lockedPlayerName = detectedName
                                playerNameLockEnabled = true
                                
                                if let fullSetName = localCard.fullSetName, !fullSetName.isEmpty {
                                    setName = fullSetName
                                }
                            }
                        }
                    }
                }
            }
            
            // Final validation
            if !playerNameLockEnabled, KnownPlayers.hasLoadedList() {
                let currentName = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !currentName.isEmpty && looksLikeBadName(currentName) {
                    let allLines = backLines + frontLines
                    if let betterName = KnownPlayers.findBestPlayerInLines(allLines) {
                        playerName = normalizePlayerNameDisplay(betterName)
                    }
                } else if currentName.isEmpty {
                    let allLines = backLines + frontLines
                    if let foundName = KnownPlayers.findBestPlayerInLines(allLines) {
                        playerName = normalizePlayerNameDisplay(foundName)
                    }
                }
            }
        }
        
        // 🆘 FALLBACK: Si on n'a TOUJOURS pas de nom mais qu'on a un numéro + set + année,
        // chercher dans la base locale pour récupérer le nom du joueur
        if playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let hasCardNumber = !cardNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasSet = !setName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasYear = !cardYear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            
            if hasCardNumber && hasSet && hasYear {
                print("🆘 OCR failed to find player name, searching local database...")
                
                // ⚠️ VALIDATION: Si le setName contient des noms d'équipes, l'ignorer
                let setNameToUse: String?
                if looksLikeTeamName(setName) {
                    print("⚠️ setName [\(setName)] contains team name, ignoring for search")
                    setNameToUse = nil
                } else {
                    setNameToUse = setName
                }
                
                if let cardByNumber = findCardByNumber(
                    cardNumber: cardNumber,
                    setName: setNameToUse,
                    year: cardYear
                ) {
                    if let foundPlayer = cardByNumber.player, !foundPlayer.isEmpty {
                        print("✅ Found player name from local database: [\(foundPlayer)]")
                        playerName = normalizePlayerNameDisplay(foundPlayer)
                        
                        // Utiliser aussi le nom complet du set
                        if let fullSetName = cardByNumber.fullSetName, !fullSetName.isEmpty {
                            setName = fullSetName
                            print("✅ Updated set name from local database: [\(fullSetName)]")
                        }
                    }
                }
            }
        }
        
        // 🔍 SECOND FALLBACK: Même si on a un nom, vérifier dans la base locale
        // pour corriger les noms partiels (ex: "Olivier Groulx" → "Benoit Olivier Groulx")
        // ET corriger les numéros mal lus (ex: "PC-5" → "PC-1" si le joueur ne correspond pas)
        if !playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let hasCardNumber = !cardNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasSet = !setName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasYear = !cardYear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            
            if hasCardNumber && hasSet && hasYear {
                // D'abord, vérifier si le numéro détecté correspond au nom détecté
                if let cardByNumber = findCardByNumber(
                    cardNumber: cardNumber,
                    setName: setName,
                    year: cardYear
                ) {
                    if let foundPlayer = cardByNumber.player, !foundPlayer.isEmpty {
                        let normalizedFound = foundPlayer.lowercased().trimmingCharacters(in: .whitespaces)
                        let normalizedCurrent = playerName.lowercased().trimmingCharacters(in: .whitespaces)
                        
                        // Si les noms ne correspondent pas du tout, c'est probablement une erreur OCR sur le numéro
                        let namesMatch = normalizedFound == normalizedCurrent || 
                                        normalizedFound.contains(normalizedCurrent) ||
                                        normalizedCurrent.contains(normalizedFound)
                        
                        if !namesMatch {
                            print("⚠️ Card number/name mismatch: [\(cardNumber)] gives [\(foundPlayer)] but OCR detected [\(playerName)]")
                            
                            // Si MVP PRIORITY LOCK est actif, ne pas corriger - vider et laisser eBay décider
                            if playerNameLockEnabled {
                                cardNumber = ""
                                print("🔄 MVP LOCK active: clearing incorrect number to let eBay frequency decide")
                            } else {
                                // Chercher le bon numéro en utilisant le nom du joueur
                                if let correctCard = findCardInLocalDatabase(
                                    playerName: playerName,
                                    setName: setName,
                                    year: cardYear
                                ) {
                                    if let correctNumber = correctCard.number, !correctNumber.isEmpty {
                                        print("🔧 Correcting card number: [\(cardNumber)] → [\(correctNumber)] based on player name")
                                        cardNumber = correctNumber
                                    
                                        // Aussi mettre à jour le nom si nécessaire
                                        if let correctCardByNumber = findCardByNumber(
                                            cardNumber: correctNumber,
                                            setName: setName,
                                            year: cardYear
                                        ) {
                                            if let correctPlayer = correctCardByNumber.player, !correctPlayer.isEmpty {
                                                playerName = normalizePlayerNameDisplay(correctPlayer)
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            // Les noms correspondent, juste mettre à jour si le nom de la base est plus complet
                            if normalizedFound.count > normalizedCurrent.count {
                                print("🔍 Upgrading partial name: [\(playerName)] → [\(foundPlayer)]")
                                playerName = normalizePlayerNameDisplay(foundPlayer)
                            }
                        }
                    }
                } else {
                    // Le numéro n'existe pas dans la base, chercher par nom
                    if let localCard = findCardInLocalDatabase(
                        playerName: playerName,
                        setName: setName,
                        year: cardYear
                    ) {
                        if let localNumber = localCard.number, !localNumber.isEmpty {
                            print("🔧 Card number [\(cardNumber)] not found, using [\(localNumber)] from player name search")
                            cardNumber = localNumber
                            
                            // Mettre à jour le nom aussi
                            if let cardByNumber = findCardByNumber(
                                cardNumber: localNumber,
                                setName: setName,
                                year: cardYear
                            ) {
                                if let foundPlayer = cardByNumber.player, !foundPlayer.isEmpty {
                                    playerName = normalizePlayerNameDisplay(foundPlayer)
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // 🛡️ VALIDATION FINALE: Bloquer les numéros avec préfixes d'équipes (WILD-5, etc.)
        if cardNumber.contains("-") {
            let teamPrefixes = ["WILD", "RANGERS", "BRUINS", "LEAFS", "OILERS", "FLAMES", 
                               "CANADIENS", "JETS", "CANUCKS", "AVALANCHE", "GOLDEN", "DEVILS",
                               "ISLANDERS", "BLUES", "KINGS", "DUCKS", "SHARKS", "SENATORS",
                               "SABRES", "RED", "BLUE", "BLACK", "WHITE", "GOLD", "SILVER",
                               "ILD", "ANGE", "RUIN", "UDC", "THE", "HIS"]
            
            let prefix = cardNumber.uppercased().components(separatedBy: "-").first ?? ""
            if teamPrefixes.contains(prefix) {
                print("🚫 FINAL VALIDATION: Blocking invalid prefix in card number: [\(cardNumber)]")
                cardNumber = ""  // Effacer le numéro invalide
            }
        }
        
        recomputePlayerNameLock()
        
        // 🧹 NETTOYAGE FINAL: Formater le nom du set (enlever année + "Upper Deck")
        if !setName.isEmpty {
            setName = formatSetName(setName)
        }
        
        processingProgress = ""
        isWorking = false
        scanPhase = .preview

        // 🚀 AUTO-TRIGGER: Lancer automatiquement le scan eBay image
        // Attendre un peu pour que l'UI se stabilise
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await scanWithEbayImage()
            
            // 🔍 FIREBASE MATCHING: DÉSACTIVÉ (Vision Framework cause blocages)
            // await matchWithFirebase()
        }
    }
    
    // MARK: - Firebase Matching
    
    private func matchWithFirebase() async {
        guard let frontImage = frontUIImage else {
            print("⚠️ No front image for Firebase matching")
            return
        }
        
        print("🔍 Starting Firebase card matching...")
        
        do {
            let matches = try await FirebaseCardMatcher.shared.findMatches(
                for: frontImage,
                limit: 3
            )
            
            await MainActor.run {
                if let bestMatch = matches.first, bestMatch.similarity > 0.80 {
                    // Si on a un bon match (>80%), OVERRIDE même si champs déjà remplis
                    print("🎯 Found high-confidence match: \(bestMatch.playerName) (similarity: \(String(format: "%.2f", bestMatch.similarity)))")
                    
                    // OVERRIDE toujours si >80%
                    playerName = normalizePlayerNameDisplay(bestMatch.playerName)
                    print("✅ OVERRIDE playerName from Firebase: \(playerName)")
                    
                    cardNumber = bestMatch.cardNumber
                    print("✅ OVERRIDE cardNumber from Firebase: \(bestMatch.cardNumber)")
                    
                    setName = bestMatch.setName
                    print("✅ OVERRIDE setName from Firebase: \(bestMatch.setName)")
                    
                    cardYear = bestMatch.year
                    print("✅ OVERRIDE cardYear from Firebase: \(bestMatch.year)")
                    
                    companyName = bestMatch.company
                    print("✅ OVERRIDE companyName from Firebase: \(bestMatch.company)")
                    
                } else if let bestMatch = matches.first {
                    print("ℹ️ Found match with lower confidence: \(bestMatch.playerName) (similarity: \(String(format: "%.2f", bestMatch.similarity)))")
                    // Ne pas auto-remplir si confiance < 80%
                } else {
                    print("ℹ️ No matches found in Firebase")
                }
            }
        } catch {
            print("❌ Firebase matching failed: \(error)")
        }
    }
    
    // MARK: - Firebase Upload
    
    private func uploadScanToFirebase(item: CardItem) async {
        // Ne pas uploader si pas d'images ou pas de données minimales
        guard let frontData = frontImageData,
              let backData = backImageData,
              !playerName.isEmpty || !cardNumber.isEmpty else {
            print("📤 Skipping Firebase upload - missing data")
            return
        }
        
        await MainActor.run {
            isUploadingToFirebase = true
            firebaseUploadStatus = "Uploading..."
        }
        
        do {
            let scanId = UUID().uuidString
            let storage = Storage.storage()
            
            // Compression pour réduire taille (~500KB par image)
            guard let frontJpeg = UIImage(data: frontData)?.jpegData(compressionQuality: 0.4),
                  let backJpeg = UIImage(data: backData)?.jpegData(compressionQuality: 0.4) else {
                print("📤 Failed to compress images")
                await MainActor.run {
                    isUploadingToFirebase = false
                    firebaseUploadStatus = ""
                }
                return
            }
            
            print("📤 Uploading scan \(scanId) to Firebase...")
            
            // Upload front image
            let frontRef = storage.reference().child("scans/\(scanId)/front.jpg")
            _ = try await frontRef.putDataAsync(frontJpeg)
            let frontUrl = try await frontRef.downloadURL().absoluteString
            
            // Upload back image
            let backRef = storage.reference().child("scans/\(scanId)/back.jpg")
            _ = try await backRef.putDataAsync(backJpeg)
            let backUrl = try await backRef.downloadURL().absoluteString
            
            // Sauvegarder metadata dans Firestore
            let db = Firestore.firestore()
            let metadata: [String: Any] = [
                "scanId": scanId,
                "ownerId": ownerId,  // ✅ IMPORTANT: Ajouter ownerId pour filtrer par utilisateur
                "playerName": playerName,
                "cardNumber": cardNumber,
                "setName": setName,
                "year": cardYear,
                "company": companyName,
                "frontUrl": frontUrl,
                "backUrl": backUrl,
                "timestamp": FieldValue.serverTimestamp(),
                "verified": false,  // User peut confirmer plus tard
                "ocrConfidence": !playerName.isEmpty && !cardNumber.isEmpty ? "high" : "low",
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            ]
            
            try await db.collection("scans").document(scanId).setData(metadata)
            
            // ✅ IMPORTANT: Sauvegarder le firebaseId dans l'item
            await MainActor.run {
                item.firebaseId = scanId
                try? modelContext.save()
                print("✅ Saved firebaseId to CardItem: \(scanId)")
            }
            
            print("✅ Firebase upload complete: \(scanId)")
            
            await MainActor.run {
                isUploadingToFirebase = false
                firebaseUploadStatus = "✅ Uploaded"
            }
            
            // Effacer le status après 2 secondes
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                firebaseUploadStatus = ""
            }
            
        } catch {
            print("❌ Firebase upload failed: \(error.localizedDescription)")
            await MainActor.run {
                isUploadingToFirebase = false
                firebaseUploadStatus = "❌ Upload failed"
            }
            
            // Effacer le status après 3 secondes
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                firebaseUploadStatus = ""
            }
        }
    }
    
    // MARK: - Retake Scan
    
    private func retakeScan() {
        frontUIImage = nil
        backUIImage = nil
        frontImageData = nil
        backImageData = nil
        frontLines = []
        backLines = []
        frontRawLines = []
        backRawLines = []
        ocrBackCardNumber = ""  // Reset protected OCR number
        playerName = ""
        cardYear = ""
        companyName = ""
        setName = ""
        cardNumber = ""
        frontFullNameDetected = nil
        backFullNameDetected = nil
        lockedPlayerName = nil
        showFlipAnimation = false
        processingProgress = ""
        scanPhase = .capturingFront
    }

    // MARK: UI helpers

    @ViewBuilder
    func thumb(_ image: UIImage?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 110, height: 150)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 110, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Aucune")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Picker open

    func openFrontCamera() {
        guard activePicker == nil else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            activePicker = .cameraFront
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.activePicker = granted ? .cameraFront : nil
                }
            }
        default:
            break
        }
    }

    func openFrontLibrary() {
        guard activePicker == nil else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else { return }
        activePicker = .libraryFront
    }

    func openBackCamera() {
        guard activePicker == nil else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            activePicker = .cameraBack
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.activePicker = granted ? .cameraBack : nil
                }
            }
        default:
            break
        }
    }

    func openBackLibrary() {
        guard activePicker == nil else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else { return }
        activePicker = .libraryBack
    }

    // MARK: Clear

    func clearFront() {
        frontUIImage = nil
        frontImageData = nil
        frontLines = []
        frontFullNameDetected = nil
        // Recompute lock when a side is cleared.
        recomputePlayerNameLock()
        // Keep detected fields (user may want to keep manual edits)
    }

    func clearBack() {
        backUIImage = nil
        backImageData = nil
        backLines = []
        ocrBackCardNumber = ""  // Reset protected OCR number

        backFullNameDetected = nil
        // Recompute lock when a side is cleared.
        recomputePlayerNameLock()
    }

    // MARK: Player name lock rules

    func nameCompareKey(_ s: String) -> String {
        // Lowercase, keep letters/numbers/spaces only, collapse spaces.
        let lower = s.lowercased()
        let mapped = lower.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == " " { return ch }
            return " "
        }
        return String(mapped)
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func looksLikeFullName(_ s: String) -> Bool {
        // 2+ tokens, each at least 2 chars
        let parts = s.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return false }
        return !parts.contains(where: { $0.count < 2 })
    }

    // MARK: - High confidence player name detection (ALL CAPS on both sides)

    func detectAllCapsFullNames(in lines: [String]) -> [String] {
        // Example: "COLE CAUFIELD" (2+ words, all caps letters)
        // We keep hyphens/apostrophes, but normalize spacing/punctuation.
        func normalizeLine(_ s: String) -> String {
            let cleaned = s
                .replacingOccurrences(of: "â€¢", with: " ")
                .replacingOccurrences(of: "Â·", with: " ")
                .replacingOccurrences(of: "â€”", with: "-")
                .replacingOccurrences(of: "â€“", with: "-")
            return cleaned
        }

        func tokenIsAllCapsWord(_ t: String) -> Bool {
            // remove non letters like commas/periods etc, keep A-Z and apostrophe/hyphen
            let stripped = t.replacingOccurrences(of: "[^A-Z'\\-]", with: "", options: String.CompareOptions.regularExpression)
            guard stripped.count >= 2 else { return false }
            return stripped == stripped.uppercased() && stripped.range(of: "[A-Z]", options: String.CompareOptions.regularExpression) != nil
        }

        var out: [String] = []
        for raw in lines {
            let line = normalizeLine(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // Quick filter: must contain at least one space (2+ words)
            guard line.contains(" ") else { continue }

            // Split on whitespace
            let parts = line
                .uppercased()
                .split(whereSeparator: { $0.isWhitespace })
                .map { String($0) }

            guard parts.count >= 2 else { continue }

            // Require all tokens look like ALL CAPS words
            guard parts.allSatisfy({ tokenIsAllCapsWord($0) }) else { continue }

            // Rebuild normalized display (Title Case)
            let display = parts
                .map { part -> String in
                    let p = part.replacingOccurrences(of: "[^A-Z'\\-]", with: "", options: String.CompareOptions.regularExpression)
                    if p.isEmpty { return "" }
                    let lower = p.lowercased()
                    return lower.prefix(1).uppercased() + lower.dropFirst()
                }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            if display.split(separator: " ").count >= 2 {
                out.append(display)
            }
        }

        // Deduplicate while preserving order
        var seen = Set<String>()
        var unique: [String] = []
        for n in out {
            let key = n.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(n)
            }
        }
        return unique
    }

    func allCapsNameIntersection(front: [String], back: [String]) -> String? {
        func key(_ s: String) -> String {
            s
                .uppercased()
                .replacingOccurrences(of: "[^A-Z ]", with: "", options: String.CompareOptions.regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: String.CompareOptions.regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let backKeys = Dictionary(uniqueKeysWithValues: back.map { (key($0), $0) })
        for f in front {
            let k = key(f)
            if let b = backKeys[k] {
                // Prefer the front display version (often cleaner)
                return f.isEmpty ? b : f
            }
        }
        return nil
    }

    func recomputePlayerNameLock() {

    // âœ… Rule #1 (existing): if the same ALL CAPS full name (2+ words) appears on BOTH front + back,
    // lock and use it immediately.
    let frontCapsNames = detectAllCapsFullNames(in: frontLines)
    let backCapsNames  = detectAllCapsFullNames(in: backLines)

    // Keep a "best guess" for UI/debug even when we don't lock.
    let frontNameLikes = detectNameLikeFullNames(in: frontLines)
    let backNameLikes  = detectNameLikeFullNames(in: backLines)

    frontFullNameDetected = frontNameLikes.first
    backFullNameDetected  = backNameLikes.first

    // 1) Exact ALL CAPS intersection (existing behavior)
    let backCapsSet = Swift.Set(backCapsNames)
    let commonCaps = frontCapsNames.filter { backCapsSet.contains($0) }
    if let bestCaps = commonCaps.sorted(by: { $0.count > $1.count }).first {
        applyLockedPlayerName(bestCaps, reason: "Front+Back ALL CAPS match")
        return
    }

    // âœ… Rule #2: if the same Title-Case-like full name (2-3 words) appears on BOTH front + back, lock it.
    let normalizedFront = Set(frontNameLikes.map(normalizeNameForCompare))
    let normalizedBack  = Set(backNameLikes.map(normalizeNameForCompare))
    let commonNameLikes = normalizedFront.intersection(normalizedBack)

    if let bestNorm = commonNameLikes.sorted(by: { $0.count > $1.count }).first {
        // Recover the original (pre-normalized) variant for nicer display
        if let original = (frontNameLikes + backNameLikes).first(where: { normalizeNameForCompare($0) == bestNorm }) {
            applyLockedPlayerName(original, reason: "Front+Back name-like match")
            return
        }
    }

    // âœ… Rule #3 (new): if 2-3 words are detected on BOTH front + back AND the canonicalized name exists in our
    // known player list (loaded from Bundle if present), lock it.
    //
    // This helps cases where OCR slightly differs between sides (or has small typos like "Fillip" vs "Filip"):
    // we canonicalize both sides against the known list, then look for an overlap.
    let frontCanonical = Set(frontNameLikes.compactMap { KnownPlayers.canonicalize($0).map(normalizeNameForCompare) })
    let backCanonical  = Set(backNameLikes.compactMap { KnownPlayers.canonicalize($0).map(normalizeNameForCompare) })
    let commonCanonical = frontCanonical.intersection(backCanonical)

    if let bestCanonNorm = commonCanonical.sorted(by: { $0.count > $1.count }).first,
       let canon = KnownPlayers.canonicalByNormalizedKey(bestCanonNorm) {
        applyLockedPlayerName(canon, reason: "Front+Back + known player list")
        return
    }
    }


    func applyLockedPlayerName(_ raw: String, reason: String? = nil) {
        _ = reason

        let locked = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locked.isEmpty else { return }

        // ðŸš« Don't ever lock an NHL team/city as a player name.
        let up = locked.uppercased()

        let nhlTeamPhrases: Set<String> = [
            "ANAHEIM DUCKS","BOSTON BRUINS","BUFFALO SABRES","CALGARY FLAMES","CAROLINA HURRICANES",
            "CHICAGO BLACKHAWKS","COLORADO AVALANCHE","COLUMBUS BLUE JACKETS","DALLAS STARS","DETROIT RED WINGS",
            "EDMONTON OILERS","FLORIDA PANTHERS","LOS ANGELES KINGS","MINNESOTA WILD","MONTREAL CANADIENS",
            "NASHVILLE PREDATORS","NEW JERSEY DEVILS","NEW YORK ISLANDERS","NEW YORK RANGERS","OTTAWA SENATORS",
            "PHILADELPHIA FLYERS","PITTSBURGH PENGUINS","SAN JOSE SHARKS","SEATTLE KRAKEN","ST. LOUIS BLUES",
            "TAMPA BAY LIGHTNING","TORONTO MAPLE LEAFS","VANCOUVER CANUCKS","VEGAS GOLDEN KNIGHTS",
            "WASHINGTON CAPITALS","WINNIPEG JETS"
        ]

        let nhlCityTokens: Set<String> = [
            "ANAHEIM","BOSTON","BUFFALO","CALGARY","CAROLINA","CHICAGO","COLORADO","COLUMBUS","DALLAS","DETROIT",
            "EDMONTON","FLORIDA","LOS","ANGELES","MINNESOTA","MONTREAL","NASHVILLE","NEW","JERSEY","YORK","OTTAWA",
            "PHILADELPHIA","PITTSBURGH","SAN","JOSE","SEATTLE","ST","LOUIS","TAMPA","BAY","TORONTO","VANCOUVER",
            "VEGAS","WASHINGTON","WINNIPEG"
        ]

        if nhlTeamPhrases.contains(up) { return }
        if nhlCityTokens.contains(up) { return }
        let parts = up.split(separator: " ").map(String.init)
        if parts.count >= 2, nhlCityTokens.contains(parts[0]) { return }

        lockedPlayerName = locked
        playerName = locked
    }

    /// Detects "human-like" full names (2+ words) even when not all caps.
    /// Example: "Filip Gustavsson"
    func detectNameLikeFullNames(in lines: [String]) -> [String] {
        lines.compactMap { raw -> String? in
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 5 else { return nil }
        // Skip anything with digits (card numbers, years, etc.)
        if s.range(of: #"\d"#, options: String.CompareOptions.regularExpression) != nil { return nil }

        // Must have 2+ words
        let words = s.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard words.count >= 2 else { return nil }

        // Reject obviously non-name phrases
        let up = s.uppercased()
        if up.contains("TRACKING SYSTEMS") { return nil }
        if up.contains("UPPER DECK") { return nil }
        if up.contains("YOUNG GUNS") { return nil }
        if up.contains("CANADIENS") { return nil }

        // Must look like capitalized words (Title Case-ish)
        let looksTitleCase = words.allSatisfy { w in
            guard let first = w.first, first.isLetter else { return false }
            // Allow hyphens/apostrophes; compare letters only
            let letters = w.filter { $0.isLetter }
            guard letters.count >= 2 else { return false }
            return String(first) == String(first).uppercased()
    }
        return (looksTitleCase && KnownPlayerNames.isKnown(s)) ? s : nil
    }
    }


/// Normalizes a player name for loose comparisons between OCR passes.
/// - Lowercases
/// - Removes diacritics
/// - Keeps letters and spaces only
/// - Collapses whitespace
    func normalizeNameForCompare(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        // Keep letters and spaces; replace anything else with a space.
        let normalizedChars = folded.map { ch -> Character in
        (ch.isLetter || ch == " ") ? ch : " "
    }

        let collapsed = String(normalizedChars)
        .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return collapsed
    }

    func nameLikeIntersection(front: [String], back: [String]) -> String? {
        guard !front.isEmpty, !back.isEmpty else { return nil }

        let normalizedFront = front.map { (orig: $0, key: normalizeNameForCompare($0)) }
        let normalizedBack  = back.map  { (orig: $0, key: normalizeNameForCompare($0)) }

        for f in normalizedFront {
        for b in normalizedBack {
            if !f.key.isEmpty, f.key == b.key {
                return f.orig
            }
    }
    }
        return nil
    }


    /// Ensures we never end up saving a "player name" that is obviously metadata noise
    /// (e.g., "NHLPA", "NHL", "Printed in Italy", etc.). Also honors the front+back name lock.
    func looksLikeBadName(_ raw: String) -> Bool {
                    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if s.isEmpty { return true }
                    if !isAsciiOrLatinOnly(s) { return true }

                    let up = s.uppercased()

                    // ðŸš« Set words that should never be part of a player name.
                    if up.contains("FUTURE WATCH") || up.contains("FUTUREWAT") || up.contains("FUTURE") { return true }
                    if up.contains("WATCH") { return true }
                    if up.contains("ICI") { return true }

                    // ðŸš« NHL team/city guardrail â€” prevents team names being chosen as a player.
                    // (Example: "MINNESOTA WILD" should never beat "Filip Gustavsson".)
                    let nhlTeamPhrases: Set<String> = [
                        "ANAHEIM DUCKS",
                        "BOSTON BRUINS",
                        "BUFFALO SABRES",
                        "CALGARY FLAMES",
                        "CAROLINA HURRICANES",
                        "CHICAGO BLACKHAWKS",
                        "COLORADO AVALANCHE",
                        "COLUMBUS BLUE JACKETS",
                        "DALLAS STARS",
                        "DETROIT RED WINGS",
                        "EDMONTON OILERS",
                        "FLORIDA PANTHERS",
                        "LOS ANGELES KINGS",
                        "MINNESOTA WILD",
                        "MONTREAL CANADIENS",
                        "NASHVILLE PREDATORS",
                        "NEW JERSEY DEVILS",
                        "NEW YORK ISLANDERS",
                        "NEW YORK RANGERS",
                        "OTTAWA SENATORS",
                        "PHILADELPHIA FLYERS",
                        "PITTSBURGH PENGUINS",
                        "SAN JOSE SHARKS",
                        "SEATTLE KRAKEN",
                        "ST. LOUIS BLUES",
                        "TAMPA BAY LIGHTNING",
                        "TORONTO MAPLE LEAFS",
                        "VANCOUVER CANUCKS",
                        "VEGAS GOLDEN KNIGHTS",
                        "WASHINGTON CAPITALS",
                        "WINNIPEG JETS",
                    ]

                    let nhlCityTokens: Set<String> = [
                        "ANAHEIM","BOSTON","BUFFALO","CALGARY","CAROLINA","CHICAGO","COLORADO","COLUMBUS","DALLAS","DETROIT",
                        "EDMONTON","FLORIDA","LOS","ANGELES","MINNESOTA","MONTREAL","NASHVILLE","NEW","JERSEY","YORK","OTTAWA",
                        "PHILADELPHIA","PITTSBURGH","SAN","JOSE","SEATTLE","ST","LOUIS","TAMPA","BAY","TORONTO","VANCOUVER",
                        "VEGAS","WASHINGTON","WINNIPEG"
                    ]

                    func isNHLTeamOrCity(_ up: String) -> Bool {
                        if nhlTeamPhrases.contains(up) { return true }
                        // If the whole string is a city token (ex: "MINNESOTA"), reject.
                        if nhlCityTokens.contains(up) { return true }
                        // If it starts with a city token and has 2+ words, reject (ex: "MINNESOTA WILD").
                        let parts = up.split(separator: " ").map(String.init)
                        if parts.count >= 2, nhlCityTokens.contains(parts[0]) { return true }
                        return false
                    }

                    if isNHLTeamOrCity(up) { return true }


                    // Common non-name tokens that often leak from the back/footer logos
                    // (or from bio/summary lines like BORN/SHOOTS/SEASONS).
                    let badContains: [String] = [
                        "NHLPA", "CONNHLPA", "NHL", "UPPER DECK", "UDC", "PRINTED", "LICENSED",
                        "ALL RIGHTS RESERVED", "Â©", "Â®",
                        "BORN", "HEIGHT", "WEIGHT", "SHOOTS", "LEFT", "RIGHT",
                        "SEASON", "SEASONS", "AHL", "OHL", "WHL", "QMJHL",
                        "AUSTRIA", "FELDKIRCH",
                    "TRACKING", "SYSTEMS", "TRACKING SYSTEMS",
                    "FUTURE", "WATCH", "FUTURE WATCH", "SP AUTHENTIC", "ICI",
                    "U-PICK", "UPICK", "U PICK", "PICK YOUR", "PICK YOUR PLAYER",
                    "CARDS YOU", "CARDS", "YOU PICK", "PICK",
                    // Series/set names that should never be player names
                    "YOUNG GUNS", "YOUNG GUN", "EXCLUSIVES", "CANVAS", "HIGH GLOSS",
                    "CLEAR CUT", "ACETATE", "ROOKIE", "ROOKIES",
                    "GAME USED", "AUTHENTIC ROOKIES", "SP GAME",
                    // NHL team names (without city) to avoid detecting them as player names
                    "DUCKS", "BRUINS", "SABRES", "FLAMES", "HURRICANES", "BLACKHAWKS",
                    "AVALANCHE", "BLUE JACKETS", "STARS", "RED WINGS", "OILERS", "PANTHERS",
                    "KINGS", "WILD", "CANADIENS", "PREDATORS", "DEVILS", "ISLANDERS", "RANGERS",
                    "SENATORS", "FLYERS", "PENGUINS", "SHARKS", "KRAKEN", "BLUES",
                    "LIGHTNING", "MAPLE LEAFS", "CANUCKS", "GOLDEN KNIGHTS", "CAPITALS", "JETS",
                    // Junior league team suffixes
                    "BATTALION", "STEELHEADS", "STORM", "COLTS", "SPIRIT", "SPITFIRES",
                    "FRONTENACS", "67S", "PETES",
                    // CRITICAL: Retired players that should NEVER appear in modern card series
                    "ZENON KONOPKA"  // Retired ~2015, causes false positives on 2024-25 cards
                    ]
                    if badContains.contains(where: { up.contains($0) }) { return true }

                    let tokens = s
                        .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "'" })
                        .map(String.init)

                    // We require at least First + Last
                    if tokens.count < 2 { return true }

                    // Reject tokens that are too short or numeric
                    if tokens.contains(where: { $0.count < 2 }) { return true }
                    if tokens.contains(where: { $0.allSatisfy { $0.isNumber } }) { return true }
                    
                    // NOTE: We used to reject names not in the known players list here, but this was too strict.
                    // Instead, we now prefer valid names over invalid ones in the assignment logic,
                    // but we don't completely reject unknown names (in case the list isn't loaded or is outdated).

                    return false
                }

    func enforcePlayerNameGuardrails() {
        

            // If we have a lock, it always wins.
            if let locked = lockedPlayerName, !locked.isEmpty {
                if playerName != locked { playerName = locked }
                return
            }

            // Recompute lock if possible, then enforce it.
            recomputePlayerNameLock()

            if let locked = lockedPlayerName, !locked.isEmpty {
                if playerName != locked { playerName = locked }
                return
            }

            // If current name is bad, prefer the best detected full name (back > front).
            let bestDetected = backFullNameDetected ?? frontFullNameDetected

            if looksLikeBadName(playerName) {
                if let candidate = bestDetected, !looksLikeBadName(candidate) {
                    playerName = normalizePlayerNameDisplay(candidate)
                } else {
                    // Better to leave it empty than persist garbage.
                    playerName = ""
                }
            }
    }

        // MARK: Handle picked


        // MARK: - eBay Debug

        @MainActor
    func setEbayDebug(
            status: String? = nil,
            queries: [String]? = nil,
            titles: [String]? = nil,
            httpStatus: Int? = nil,
            usedUrl: String? = nil,
            bodyPreview: String? = nil,
            errorMessage: String? = nil,
            source: String? = nil
        ) {
            if let status { self.ebayDebugStatus = status }
            if let queries { self.ebayDebugLastQueries = queries }
            if let titles { self.ebayDebugTitles = titles }
            if let httpStatus { self.ebayDebugHttpStatus = httpStatus }
            if let usedUrl { self.ebayDebugUsedUrl = usedUrl }
            if let bodyPreview { self.ebayDebugBodyPreview = bodyPreview }
            if let errorMessage { self.ebayDebugErrorMessage = errorMessage }
            if let source { self.ebayDebugSource = source }
            self.ebayDebugLastUpdated = Date()
    }


    func runEbayGeneralTest() async {
            let q = "Upper Deck 2025-26 Young Guns #207"
            await MainActor.run {
                setEbayDebug(
                    status: "Rechercheâ€¦",
                    queries: [q],
                    titles: [],
                    httpStatus: nil,
                    usedUrl: "",
                    bodyPreview: "",
                    errorMessage: "",
                    source: ""
                )
            }

            let (titles, source, usedUrl, http, body, err) = await EbaySoftCorrector.searchItemTitlesDebug(query: q, limit: 10, soldOnly: false)

            await MainActor.run {
                if let err, !err.isEmpty {
                    setEbayDebug(
                        status: "Erreur",
                        titles: titles,
                        httpStatus: http,
                        usedUrl: usedUrl,
                        bodyPreview: body,
                        errorMessage: err,
                        source: source
                    )
                } else {
                    setEbayDebug(
                        status: "OK (\(titles.count) rÃ©sultats)",
                        titles: titles,
                        httpStatus: http,
                        usedUrl: usedUrl,
                        bodyPreview: body,
                        errorMessage: "",
                        source: source
                    )
                }
            }
    }

    func handleFront(_ img: UIImage) {
            isWorking = true

            frontUIImage = img
            frontImageData = img.jpegData(compressionQuality: 0.92)

            // Cancel any in-flight OCR for front (prevents UI stalls / race conditions)
            frontOCRTask?.cancel()
            frontOCRTask = Task {
                let result = await Task.detached(priority: .userInitiated) { () -> (raw: [String], clean: [String], parsed: FrontOCRParser.FrontResult?) in
                    let rawLines = await OCR.runMultiPass(on: img, note: "front")
                    let cleanLines = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    let parsed = await MainActor.run { FrontOCRParser.parse(lines: cleanLines) }
                    return (rawLines, cleanLines, parsed)
                }.value

                if Task.isCancelled { return }

                await MainActor.run {
                    frontRawLines = result.raw
                    frontLines = result.clean

                    if let parsed = result.parsed {
                        // Back is usually more reliable.

                        // Year: back wins when present (helps avoid stats-table years).
                        if let y = parsed.year, !y.isEmpty {
                            cardYear = normalizeYear(y)
                        }

                        // Company: only override when empty.
                        if companyName.isEmpty, let b = parsed.company {
                            companyName = b
                        }

                        // Set: prefer back when it adds meaningful info (ex: "Future Watch")
                        if let s = parsed.setName, !s.isEmpty {
                            if setName.isEmpty {
                                setName = s
                            } else {
                                let cur = setName.uppercased()
                                let inc = s.uppercased()
                                if inc.contains("FUTURE WATCH") && !cur.contains("FUTURE WATCH") {
                                    setName = s
                                }
                            }
                        }

                        // âœ… RÃ¨gle Cardia: le numÃ©ro de carte vient toujours du DOS (back).
                        // EXCEPTION: Les cartes spÃ©ciales (PC-, SR-, TS-, etc.) ont leur numÃ©ro sur le DEVANT.
                        if let frontNum = parsed.cardNumber, !frontNum.isEmpty {
                            let up = frontNum.uppercased()
                            // Accept front number if it has a special prefix
                            let specialPrefixes = ["PC-", "SR-", "TS-", "FWA-", "CQ-", "CC-", "AC-", "HC-"]
                            if specialPrefixes.contains(where: { up.hasPrefix($0) }) {
                                cardNumber = frontNum
                            }
                        }

                        // Player name: allow back to override when current looks bad (ex: "NAZAR ICI") or is empty.
                        if let p = parsed.fullName, !p.isEmpty, !playerNameLockEnabled {
                            let shouldReplace = playerName.isEmpty 
                                || looksLikeBadName(playerName) 
                                || p.count >= playerName.count + 2
                                || (KnownPlayers.hasLoadedList() 
                                    && KnownPlayers.canonicalize(p) != nil 
                                    && KnownPlayers.canonicalize(playerName) == nil)
                            
                            if shouldReplace {
                                // If we can canonicalize, use the canonical form for consistency
                                if let canonical = KnownPlayers.canonicalize(p) {
                                    playerName = normalizePlayerNameDisplay(canonical)
                                } else {
                                    playerName = normalizePlayerNameDisplay(p)
                                }
                            }
                        }
                    }

                    // âœ… This will trigger the ALL-CAPS front+back rule, now that lines are cleaned.
                    recomputePlayerNameLock()

                    isWorking = false
                }

                // After back OCR, try eBay assist more aggressively (won't override lock)
                // âš ï¸ TEMPORAIREMENT DÃ‰SACTIVÃ‰ POUR DEBUG ZENON KONOPKA
                // await tryEbayAutofillPlayerName(forceOverride: false)
            }
    }

    func handleBack(_ img: UIImage) {
            isWorking = true

            backUIImage = img
            backImageData = img.jpegData(compressionQuality: 0.92)

            // Cancel any in-flight OCR for back
            backOCRTask?.cancel()
            backOCRTask = Task {
                let result = await Task.detached(priority: .userInitiated) { () -> (raw: [String], clean: [String], parsed: BackOCRParser.Result) in
                    let rawLines = await OCR.runMultiPass(on: img, note: "back")
                    let cleanLines = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    let parsed = await MainActor.run { BackOCRParser.parse(lines: cleanLines, companyHint: nil) }
                    return (rawLines, cleanLines, parsed)
                }.value

                if Task.isCancelled { return }

                await MainActor.run {
                    backRawLines = result.raw
                    backLines = result.clean

                    let parsed = result.parsed

                    // Year: back wins when present (helps avoid stats-table years).
                    if let y = parsed.year, !y.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        cardYear = normalizeYear(y.trimmingCharacters(in: .whitespacesAndNewlines))
                    }

                    // Company: back is reliable.
                    if let c = parsed.company, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if companyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            companyName = c.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }

                    // Set: back is typically the truth (ex: "Future Watch").
                    if let s = parsed.setName, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let incoming = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if setName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            setName = incoming
                        } else {
                            // If back adds "FUTURE WATCH", prefer it.
                            let cur = setName.uppercased()
                            let inc = incoming.uppercased()
                            if inc.contains("FUTURE WATCH") && !cur.contains("FUTURE WATCH") {
                                setName = incoming
                            }
                        }
                    }

                    // âœ… RÃ¨gle Cardia: le numÃ©ro de carte vient TOUJOURS du DOS.
                    if let n = parsed.cardNumber, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Prefer alphanumeric codes (TS-30) over short 1-digit codes (C-8).
                        let candidate = n.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cur = cardNumber.trimmingCharacters(in: .whitespacesAndNewlines)

                        func score(_ s: String) -> Int {
                            let up = s.uppercased()
                            var sc = 0
                            if up.range(of: #"^[A-Z]{1,4}-\d{1,4}$"#, options: String.CompareOptions.regularExpression) != nil { sc += 200 }
                            // HUGE bonus for special card prefixes - these are the REAL card numbers!
                            if up.hasPrefix("PC-") { sc += 1000 }  // Population Count
                            if up.hasPrefix("SR-") { sc += 1000 }  // Sizzle Reel
                            if up.hasPrefix("TS-") { sc += 1000 }  // Team Set
                            if up.hasPrefix("FWA-") { sc += 1000 } // Future Watch
                            if up.hasPrefix("CQ-") { sc += 1000 }  // Cup Quest
                            if up.hasPrefix("CC-") { sc += 1000 }  // Clear Cut
                            if up.hasPrefix("AC-") { sc += 1000 }  // Acetate
                            if up.hasPrefix("HC-") { sc += 1000 }  // High Gloss
                            // Normal 1-3 digit numbers (like 202, 484) get moderate score
                            if up.range(of: #"^\d{1,2}$"#, options: String.CompareOptions.regularExpression) != nil { sc += 120 }
                            // 3-digit numbers (like 500, 999) are likely serial/population numbers, NOT card numbers
                            if up.range(of: #"^\d{3}$"#, options: String.CompareOptions.regularExpression) != nil { sc -= 200 }
                            if up.contains("/") { sc -= 500 } // serial like 907/999
                            if up.range(of: #"^\d{4}-\d{2}$"#, options: String.CompareOptions.regularExpression) != nil { sc -= 500 } // year
                            return sc
                        }

                        if cur.isEmpty || score(candidate) >= score(cur) {
                            cardNumber = candidate
                        }
                    }

                    // Player name: allow back to override when current looks bad or is empty (unless locked).
                    if let p = parsed.fullName, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !playerNameLockEnabled {
                        let incoming = p.trimmingCharacters(in: .whitespacesAndNewlines)
                        let shouldReplace = playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty 
                            || looksLikeBadName(playerName) 
                            || incoming.count >= playerName.count + 2
                            || (KnownPlayers.hasLoadedList() 
                                && KnownPlayers.canonicalize(incoming) != nil 
                                && KnownPlayers.canonicalize(playerName) == nil)
                        
                        if shouldReplace {
                            // If we can canonicalize, use the canonical form for consistency
                            if let canonical = KnownPlayers.canonicalize(incoming) {
                                playerName = canonical
                            } else {
                                playerName = incoming
                            }
                        }
                    }

                    // Apply guardrails after back pass.
                    enforcePlayerNameGuardrails()

                    // âœ… This will trigger the ALL-CAPS front+back rule, now that lines are cleaned.
                    recomputePlayerNameLock()
                    
                    // ðŸ” FINAL VALIDATION: If we have a known players list and the detected name is NOT in it,
                    // actively search all OCR lines for the best matching player name.
                    // This catches cases where OCR detects garbage like "Brampton Battalion" instead of "Gabe Perreault".
                    // CRITICAL: ONLY search for replacement if name is EXPLICITLY bad (in bad list).
                    // NEVER replace a valid-looking "First Last" name even if not in known list.
                    if !playerNameLockEnabled, KnownPlayers.hasLoadedList() {
                        let currentName = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !currentName.isEmpty {
                            // ONLY search for replacement if name is EXPLICITLY in bad list
                            // DO NOT search just because name is not in known list
                            if looksLikeBadName(currentName) {
                                let allLines = backLines + frontLines
                                if let betterName = KnownPlayers.findBestPlayerInLines(allLines) {
                                    playerName = betterName
                                }
                            }
                        } else {
                            // If we have no name at all, search for one
                            let allLines = backLines + frontLines
                            if let foundName = KnownPlayers.findBestPlayerInLines(allLines) {
                                playerName = foundName
                            }
                        }
                    }

                    isWorking = false
                }

                // After back OCR, try eBay assist more aggressively (won't override lock)
                // âš ï¸ TEMPORAIREMENT DÃ‰SACTIVÃ‰ POUR DEBUG ZENON KONOPKA
                // await tryEbayAutofillPlayerName(forceOverride: false)
            }
    }


        // MARK: eBay soft auto-fill (player name)

        /// Tries to improve / auto-fill the player name using eBay titles.
        /// This is intentionally "soft": we only apply when confidence is strong or OCR name is empty.
        @MainActor
    func tryEbayAutofillPlayerName(forceOverride: Bool = false) async {
            print("ðŸ”µ tryEbayAutofillPlayerName called - forceOverride: \(forceOverride), locked: \(lockedPlayerName != nil ? "YES" : "NO"), current playerName: [\(playerName)]")
            
            if forceOverride {
                // User explicitly requested eBay correction.
                lockedPlayerName = nil
                print("ðŸ”“ User forced override - unlocking playerName")
            }
            // Debug/UI feedback so the user sees that something is happening
            ebayDebugStatus = "Recherche eBayâ€¦"
            ebayDebugLastUpdated = Date()
            ebayDebugResponseBody = ""
            ebayDebugLastQuery = ""
            ebayDebugLastTriedQueries = []
            ebayDebugHttpStatusCode = nil
            ebayDebugUrl = nil
            ebayDebugIsUsingProxy = nil



            guard CVPhotoOCRAddCardView.isEbayConfigured() else { return }

            let y = cardYear.trimmingCharacters(in: .whitespacesAndNewlines)
            let c = companyName.trimmingCharacters(in: .whitespacesAndNewlines)
            let s = setName.trimmingCharacters(in: .whitespacesAndNewlines)
            let n = cardNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            let current = playerName.trimmingCharacters(in: .whitespacesAndNewlines)

            // eBay debug (requÃªte + rÃ©sultats)
            ebayDebugStatus = "Recherche en coursâ€¦"

            let queries = EbaySoftCorrector.buildSearchQueries(year: y, company: c, set: s, cardNumber: n)
            if queries.isEmpty {
                ebayDebugQuery = ""
            } else {
                ebayDebugQuery = queries.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: "\n")
            }
            ebayDebugTitles = []

            func tokens(_ name: String) -> [String] {
                name
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                    .map { String($0) }
                    .filter { !$0.isEmpty }
            }

            func alphaKey(_ s: String) -> String {
                let up = s.uppercased()
                let letters = up.unicodeScalars.filter { CharacterSet.letters.contains($0) }
                return String(String.UnicodeScalarView(letters))
            }

            func containsSurname(_ fullName: String, surname: String) -> Bool {
                let sur = alphaKey(surname)
                guard !sur.isEmpty else { return false }
                let parts = tokens(fullName).map(alphaKey)
                return parts.contains(sur)
            }

        
            // Similarity helper: if OCR produced a near-miss of the real name (e.g., WARNER vs MARNER),
            // and eBay strongly suggests a candidate, we should override the OCR.
            func namesNearMatch(_ a: String, _ b: String) -> Bool {
                let ta = tokens(a)
                let tb = tokens(b)
                guard ta.count >= 2, tb.count >= 2 else { return false }
                let firstA = alphaKey(ta[0])
                let firstB = alphaKey(tb[0])
                guard !firstA.isEmpty, firstA == firstB else { return false }

                let lastA = alphaKey(ta.last ?? "")
                let lastB = alphaKey(tb.last ?? "")
                guard !lastA.isEmpty, !lastB.isEmpty else { return false }

                // Allow 1â€“2 char OCR swaps in surname
                let dist = levenshteinDistance(lastA, lastB)
                let maxLen = max(lastA.count, lastB.count)
                if dist <= 1 { return true }
                if maxLen <= 10 && dist <= 2 { return true }
                return false
            }

            func levenshteinDistance(_ s: String, _ t: String) -> Int {
                let a = Array(s)
                let b = Array(t)
                if a.isEmpty { return b.count }
                if b.isEmpty { return a.count }

                var prev = Array(0...b.count)
                var cur = Array(repeating: 0, count: b.count + 1)

                for i in 1...a.count {
                    cur[0] = i
                    for j in 1...b.count {
                        let cost = (a[i - 1] == b[j - 1]) ? 0 : 1
                        cur[j] = min(
                            prev[j] + 1,
                            cur[j - 1] + 1,
                            prev[j - 1] + cost
                        )
                    }
                    prev = cur
                }
                return prev[b.count]
            }

        let currentParts = tokens(current)
            let isSurnameOnly = (currentParts.count == 1 && !currentParts[0].isEmpty)

            // âœ… Strong path: when we have structured keys, always ask eBay to fill unknowns and (especially) player name.
            if !y.isEmpty, !c.isEmpty, !s.isEmpty, !n.isEmpty {
                if let suggestion = await EbaySoftCorrector.playerNameSuggestion(
                    year: y,
                    company: c,
                    set: s,
                    cardNumber: n,
                    currentPlayerName: current
                ) {
                    ebayNameCandidate = suggestion.name
                    ebayNameConfidence = suggestion.confidence
                    ebayNameTitle = suggestion.titleMatched ?? ""
                    ocrNameForComparison = current
                    ebayDebugTitles = suggestion.titles
                    // Met Ã  jour l'affichage de debug pour montrer quelle requÃªte a matchÃ©.
                    let qList = suggestion.triedQueries
                    if qList.isEmpty {
                        ebayDebugQuery = ""
                    } else {
                        ebayDebugQuery = qList.enumerated().map { pair in
                            let idx = pair.offset
                            let q = pair.element
                            let mark = (suggestion.queryUsed == q) ? "âœ… " : ""
                            return "\(idx + 1)) \(mark)\(q)"
                        }.joined(separator: "\n")
                    }
                    ebayDebugLastUpdated = Date()
                    ebayDebugStatus = "OK"
                    if forceOverride {
                        ebayDebugStatus = "OK (override nom joueur)"
                    }

                    if forceOverride {
                        // Helper: validate if set looks real or is OCR garbage
                        func isValidSet(_ s: String) -> Bool {
                            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty { return false }
                            if trimmed.count < 3 { return false }
                            
                            // Reject sets with strange characters
                            let allowedChars = CharacterSet.alphanumerics.union(CharacterSet.whitespaces).union(CharacterSet(charactersIn: "-"))
                            if trimmed.rangeOfCharacter(from: allowedChars.inverted) != nil { return false }
                            
                            let upper = trimmed.uppercased()
                            if upper.contains("YOUNG GUNS") || upper.contains("SERIES") || upper.contains("E-X") || 
                               upper.contains("EX") || upper.contains("AUTHENTIC") || upper.contains("EXCLUSIVES") { 
                                return true 
                            }
                            if trimmed.rangeOfCharacter(from: .decimalDigits) != nil { return true }
                            
                            let words = trimmed.split(separator: " ").map(String.init)
                            if words.count >= 2 && words.allSatisfy({ $0.count >= 3 }) { return true }
                            if words.count == 1 && words[0].count >= 5 { return true }
                            
                            return false
                        }
                        
                        // CRITICAL PROTECTION: If OCR detected NOTHING and set is invalid,
                        // the eBay search is too broad (e.g. "2022-23 #105" matches any #105)
                        // In this case, REJECT the override to prevent false matches
                        let ocrIsEmpty = current.isEmpty || current.count < 3
                        let setIsInvalid = !isValidSet(s)
                        
                        if ocrIsEmpty && setIsInvalid {
                            ebayDebugStatus = "REJETÃ‰: OCR vide + set invalide = recherche trop large"
                            return
                        }
                        
                        let forced = ebayNameCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !forced.isEmpty {
                            // Strategy 1: Try sanitizedPlayerName (extracts name from complex strings)
                            if let cleaned = sanitizedPlayerName(forced, allowSingleWord: false) {
                                playerName = cleaned
                                lockedPlayerName = cleaned
                                ebayDebugStatus = "OK (override - Strategy 1: \(cleaned))"
                                return
                            }
                            
                            // Strategy 2: Try KnownPlayers.canonicalize (validates against player list)
                            if let canonical = KnownPlayers.canonicalize(forced) {
                                playerName = canonical
                                lockedPlayerName = canonical
                                ebayDebugStatus = "OK (override - Strategy 2: \(canonical))"
                                return
                            }
                            
                            // Strategy 3: Try findBestPlayerInLines (searches for player names in text)
                            if let found = KnownPlayers.findBestPlayerInLines([forced]) {
                                playerName = found
                                lockedPlayerName = found
                                ebayDebugStatus = "OK (override - Strategy 3: \(found))"
                                return
                            }
                            
                            // Strategy 4: Extract first two words as "First Last" (fallback)
                            let words = forced.split(separator: " ").map(String.init).filter { !$0.isEmpty }
                            if words.count >= 2 {
                                let candidate = "\(words[0]) \(words[1])"
                                if let canonical = KnownPlayers.canonicalize(candidate) {
                                    playerName = canonical
                                    lockedPlayerName = canonical
                                    ebayDebugStatus = "OK (override - Strategy 4a: \(canonical))"
                                    return
                                }
                                // Even if not in list, if eBay strongly suggests it with high confidence
                                // and it looks like a proper name, accept it
                                if ebayNameConfidence ?? 0 >= 0.70 {
                                    let looksValid = words[0].first?.isUppercase == true 
                                                  && words[1].first?.isUppercase == true
                                                  && words[0].count >= 3 
                                                  && words[1].count >= 3
                                    if looksValid {
                                        playerName = candidate
                                        lockedPlayerName = candidate
                                        ebayDebugStatus = "OK (override - Strategy 4b: \(candidate))"
                                        return
                                    }
                                }
                            }
                            
                            // Strategy 5: LAST RESORT - If user explicitly clicked "Verify on eBay"
                            // and we have reasonable confidence, assign the raw eBay result
                            // This ensures the user gets SOMETHING rather than nothing
                            // CRITICAL: Lower threshold to 0.30 for forceOverride (user explicitly asked)
                            if ebayNameConfidence ?? 0 >= 0.30 {
                                // Clean up the text minimally
                                let cleaned = forced
                                    .replacingOccurrences(of: " YG", with: "")
                                    .replacingOccurrences(of: " RC", with: "")
                                    .replacingOccurrences(of: " #PC", with: "")
                                    .replacingOccurrences(of: "#PC", with: "")
                                    .replacingOccurrences(of: " PC", with: "")
                                    .replacingOccurrences(of: "#", with: "")
                                    .replacingOccurrences(of: " /", with: "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                
                                // Try to extract just first two words if multi-word
                                let cleanWords = cleaned.split(separator: " ").map(String.init)
                                if cleanWords.count >= 2 {
                                    let twoWords = "\(cleanWords[0]) \(cleanWords[1])"
                                    playerName = twoWords
                                    lockedPlayerName = twoWords
                                    ebayDebugStatus = "OK (override - Strategy 5: \(twoWords))"
                                    return
                                } else if !cleaned.isEmpty {
                                    playerName = cleaned
                                    lockedPlayerName = cleaned
                                    ebayDebugStatus = "OK (override - Strategy 5: \(cleaned))"
                                    return
                                }
                            }
                            
                            // Strategy 6: ABSOLUTE LAST RESORT - Assign SOMETHING if user clicked
                            // Even if confidence is low or unknown, try to extract a name
                            let cleanWords = forced.split(separator: " ").map(String.init).filter { !$0.isEmpty }
                            if cleanWords.count >= 2 {
                                let twoWords = "\(cleanWords[0]) \(cleanWords[1])"
                                playerName = twoWords
                                lockedPlayerName = twoWords
                                ebayDebugStatus = "OK (override - Strategy 6 FORCED: \(twoWords))"
                            } else if !forced.isEmpty {
                                playerName = forced
                                lockedPlayerName = forced
                                ebayDebugStatus = "OK (override - Strategy 6 FORCED: \(forced))"
                            } else {
                                ebayDebugStatus = "FAILED (override - ebayNameCandidate is empty!)"
                            }
                        }
                        return
                    }

                    // Apply:
                    // - If OCR empty -> apply
                    // - If OCR surname-only and eBay suggestion contains that surname -> apply (lower threshold)
                    // - If OCR is a near-miss of the suggested name (e.g., WARNER vs MARNER) -> apply with a moderate threshold
                    // - If eBay name is in KnownPlayers and OCR name is NOT -> apply (prefer validated names)
                    // - Otherwise, apply only when confidence is high
                    if (lockedPlayerName?.isEmpty ?? true) {
                        if current.isEmpty {
                            if let cleaned = sanitizedPlayerName(suggestion.name, allowSingleWord: false) { playerName = cleaned }
                            if forceOverride { if let cleaned = sanitizedPlayerName(suggestion.name, allowSingleWord: false) { lockedPlayerName = cleaned } }
                        } else if isSurnameOnly, containsSurname(suggestion.name, surname: current) {
                            if suggestion.confidence >= 0.45 {
                                if let cleaned = sanitizedPlayerName(suggestion.name, allowSingleWord: false) { playerName = cleaned }
                            if forceOverride { if let cleaned = sanitizedPlayerName(suggestion.name, allowSingleWord: false) { lockedPlayerName = cleaned } }
                            }
                        } else if namesNearMatch(current, suggestion.name) {
                            // OCR commonly swaps 1â€“2 letters in the surname; eBay aggregation is usually more reliable here.
                            if suggestion.confidence >= 0.55 {
                                if let cleaned = sanitizedPlayerName(suggestion.name, allowSingleWord: false) { playerName = cleaned }
                            if forceOverride { if let cleaned = sanitizedPlayerName(suggestion.name, allowSingleWord: false) { lockedPlayerName = cleaned } }
                            }
                        } else if KnownPlayers.hasLoadedList() 
                                  && KnownPlayers.canonicalize(suggestion.name) != nil 
                                  && KnownPlayers.canonicalize(current) == nil 
                                  && suggestion.confidence >= 0.50 {
                            // NEW: If eBay name is validated and OCR name is not, prefer eBay (with moderate confidence)
                            if let cleaned = sanitizedPlayerName(suggestion.name, allowSingleWord: false) { playerName = cleaned }
                            if forceOverride { if let cleaned = sanitizedPlayerName(suggestion.name, allowSingleWord: false) { lockedPlayerName = cleaned } }
                        } else if suggestion.confidence >= 0.78 {
                            if let cleaned = sanitizedPlayerName(suggestion.name, allowSingleWord: false) { playerName = cleaned }
                            if forceOverride { if let cleaned = sanitizedPlayerName(suggestion.name, allowSingleWord: false) { lockedPlayerName = cleaned } }
                        }
                    }

                    // âœ… Minimum viable: try to infer set name ("Series 2 Young Guns") from eBay titles + card number
                    if let setSuggestion = EbaySoftCorrector.setNameSuggestionMinimumViable(
                        currentSetName: setName,
                        company: companyName,
                        cardNumber: cardNumber,
                        titles: suggestion.titles
                    ) {
                        setName = normalizeSetName(company: companyName, rawSetName: setSuggestion)
                    }
                } else {
                    ebayDebugStatus = "Aucun rÃ©sultat"
                    ebayDebugLastUpdated = Date()
                }

                // Important: the preferred path returns early; ensure we still apply the name guardrails.
                enforcePlayerNameGuardrails()
                return
            }

            // Fallback: fewer keys â€” still try to improve name when OCR is empty / surname-only.
            if let best = await EbaySoftCorrector.suggestPlayerName(
                currentPlayerName: current,
                year: y.isEmpty ? nil : y,
                company: c.isEmpty ? nil : c,
                setName: s.isEmpty ? nil : s,
                cardNumber: n.isEmpty ? nil : n
            ) {
                let display = normalizePlayerNameDisplay(best)
                ebayNameCandidate = display
                ebayNameConfidence = nil
                ebayNameTitle = ""
                ocrNameForComparison = current

                if (lockedPlayerName?.isEmpty ?? true) {
                    if current.isEmpty || (isSurnameOnly && containsSurname(display, surname: current)) {
                        playerName = display
                    }
                }
            } else {
                ebayDebugStatus = "Aucun rÃ©sultat"
                ebayDebugLastUpdated = Date()
            }

            enforcePlayerNameGuardrails()


    }

        // MARK: Manual eBay verification (button)

        @MainActor
    func verifyOnEbayButtonTapped() async {
            guard CVPhotoOCRAddCardView.isEbayConfigured() else { return }
            isWorking = true
            defer { isWorking = false }

            lockedPlayerName = nil

            await tryEbayAutofillPlayerName(forceOverride: true)
    }

        // MARK: eBay Image Search
    
        @MainActor
    
    // MARK: - Final Cross-Validation
    
    /// Validation croisée finale: vérifie que le nom du joueur correspond au numéro de carte dans la base
    /// S'exécute APRÈS toutes les sources (OCR + eBay) pour corriger les incohérences
    private func performFinalCrossValidation() {
        guard !cardNumber.isEmpty else {
            print("⚠️ Cross-validation skipped: cardNumber is empty")
            return
        }
        
        print("🔍 Final cross-validation: card=[\(cardNumber)], player=[\(playerName)], set=[\(setName)], year=[\(cardYear)]")
        
        // Chercher dans la base si ce numéro existe (essayer avec et sans année)
        var cardByNumber = findCardByNumber(
            cardNumber: cardNumber,
            setName: setName.isEmpty ? nil : setName,
            year: cardYear.isEmpty ? nil : cardYear
        )
        
        // Si toujours pas trouvé, essayer sans setName (mais garder l'année)
        if cardByNumber == nil && !cardYear.isEmpty {
            print("🔄 Retrying cross-validation without set filter (keeping year)")
            cardByNumber = findCardByNumber(
                cardNumber: cardNumber,
                setName: nil,
                year: cardYear
            )
        }
        
        // 🆘 DERNIER RECOURS: Si toujours rien trouvé ET que le numéro est préfixé ET qu'on a un nom valide,
        // essayer sans année (l'OCR de l'année peut être très mauvais)
        if cardByNumber == nil && cardNumber.contains("-") && !playerName.isEmpty {
            let playerIsValid = KnownPlayerNames.isKnown(playerName) || KnownPlayers.canonicalize(playerName) != nil
            if playerIsValid {
                print("🆘 Last resort: Searching prefixed number [\(cardNumber)] without year filter (OCR year might be wrong)")
                cardByNumber = findCardByNumber(
                    cardNumber: cardNumber,
                    setName: nil,
                    year: nil
                )
            }
        }
        
        guard let cardByNumber = cardByNumber else {
            print("⚠️ Cross-validation skipped: card [\(cardNumber)] not found in database")
            return
        }
        
        guard let foundPlayer = cardByNumber.player, !foundPlayer.isEmpty else {
            print("⚠️ Cross-validation skipped: no player name in database for card [\(cardNumber)]")
            return
        }
        
        // TOUJOURS utiliser le nom de la base si on a trouvé la carte
        // Sauf si les noms correspondent déjà parfaitement
        let foundNormalized = foundPlayer.uppercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let currentNormalized = playerName.uppercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        
        // Vérifier si les noms correspondent (exact ou contient)
        let namesMatch = foundNormalized == currentNormalized ||
                        (!foundNormalized.isEmpty && !currentNormalized.isEmpty && (
                            foundNormalized.contains(currentNormalized) ||
                            currentNormalized.contains(foundNormalized)
                        ))
        
        if !namesMatch || playerName.isEmpty {
            // 🔒 MVP PROTECTION: Si le nom est locké (MVP priority lock), ne PAS écraser
            if playerNameLockEnabled {
                print("🔒 MVP with locked name - blocking cross-validation override. Keeping [\(playerName)] despite DB suggesting [\(foundPlayer)]")
                return
            }
            
            // Vérifier si les noms ont au moins un mot significatif en commun
            let foundWords = Set(foundNormalized.split(separator: " ").filter { $0.count > 2 })
            let currentWords = Set(currentNormalized.split(separator: " ").filter { $0.count > 2 })
            let commonWords = foundWords.intersection(currentWords)
            
            // Si AUCUN mot en commun, rejeter la cross-validation (probablement mauvais joueur)
            if commonWords.isEmpty && !playerName.isEmpty {
                print("⚠️ CROSS-VALIDATION REJECTED: Card [\(cardNumber)] belongs to [\(foundPlayer)], which has NO common words with [\(playerName)] - keeping current name")
                return
            }
            
            print("❌ CROSS-VALIDATION FAILED: Card [\(cardNumber)] belongs to [\(foundPlayer)], not [\(playerName)]")
            playerName = normalizePlayerNameDisplay(foundPlayer)
            print("✅ Corrected player name to: [\(playerName)]")
            
            // Mettre à jour aussi le set si disponible
            if let fullSetName = cardByNumber.fullSetName, !fullSetName.isEmpty {
                print("✅ Updated set name to: [\(fullSetName)]")
                setName = fullSetName
            }
        } else {
            print("✅ Cross-validation passed: [\(playerName)] matches [\(cardNumber)]")
        }
    }
    
    func scanWithEbayImage() async {
        guard let image = frontUIImage else {
            imageSearchStatus = "âŒ Aucune image disponible"
            return
        }
        
        isImageSearching = true
        imageSearchStatus = "ðŸ” Analyse de l'image en cours..."
        ebayDebugStatus = "Image Search en cours..."
        
        do {
            let result = try await EbayImageSearch.searchAndPopulateFields(
                image: image,
                currentYear: cardYear,
                currentCompany: companyName,
                currentSet: setName,
                currentNumber: cardNumber,
                currentPlayer: playerName
            )
            
            // VÃ©rifier si on a trouvÃ© quelque chose d'utile
            let foundSomething = !result.playerName.isEmpty || !result.year.isEmpty
            
            // DEBUG: Afficher ce qui a Ã©tÃ© parsÃ©
            print("ðŸ” eBay Image Search - Parsed values:")
            print("  Player: [\(result.playerName)]")
            print("  Year: [\(result.year)]")
            print("  Company: [\(result.company)]")
            print("  Set: [\(result.setName)]")
            print("  Number: [\(result.cardNumber)]")
            print("  Confidence: \(result.confidence)")
            
            if foundSomething && result.confidence > 0.3 {
                // 🛡️ VALIDATION GLOBALE: Vérifier la cohérence de l'année eBay avec l'OCR
                // Si l'année diffère de plus de 2 ans, rejeter TOUS les résultats eBay
                var ebayResultsValid = true
                if !result.year.isEmpty && !cardYear.isEmpty {
                    let ebayYear = normalizeYear(result.year)
                    let ocrYearNum = Int(cardYear.prefix(4)) ?? 0
                    let ebayYearNum = Int(ebayYear.prefix(4)) ?? 0
                    let yearDiff = abs(ocrYearNum - ebayYearNum)
                    
                    if yearDiff > 2 {
                        print("⚠️⚠️ REJECTING ALL eBay results: year [\(ebayYear)] differs by \(yearDiff) years from OCR year [\(cardYear)]")
                        ebayResultsValid = false
                    }
                }
                
                if ebayResultsValid {
                // Remplir les champs
                if !result.playerName.isEmpty {
                    // 🔒 PROTECTION: Si playerName est déjà locké (ex: MVP PRIORITY LOCK), ne pas l'écraser
                    if playerNameLockEnabled {
                        print("🔒 Player name already locked to [\(lockedPlayerName ?? "nil")], ignoring eBay name [\(result.playerName)]")
                    } else {
                        // 🔍 Validation du nom eBay et comparaison avec le nom actuel
                    let currentName = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let ebayName = result.playerName.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // Vérifier si c'est une carte Population Count
                    let isPopulationCount = result.debugInfo.range(of: "Population Count", options: .caseInsensitive) != nil
                    
                    // Blacklist de phrases communes qui ne sont pas des noms de joueurs
                    let invalidPhrases = ["Pick From", "Choose Any", "Choose From", "Select Any", 
                                          "U Pick", "You Pick", "Your Choice", "Multiple Available",
                                          "Population Count", "High Gloss", "Clear Cut", "Exclusives",
                                          "UD Canvas", "Canvas", "Portraits", "Overtime", "Quad Jersey",
                                          "Triple Jersey", "Dual Jersey", "Game Jersey", "Rookie Materials",
                                          "Watch Horizontal", "Future Watch", "SP Authentic", "Sizzle Reel"]
                    let ebayIsInvalid = invalidPhrases.contains { phrase in
                        ebayName.range(of: phrase, options: .caseInsensitive) != nil
                    }
                    let currentIsInvalid = invalidPhrases.contains { phrase in
                        currentName.range(of: phrase, options: .caseInsensitive) != nil
                    }
                    
                    // Vérifier si les noms sont dans la liste de joueurs connus
                    let ebayIsKnown = !ebayIsInvalid && (KnownPlayerNames.isKnown(ebayName) || KnownPlayers.canonicalize(ebayName) != nil)
                    let currentIsKnown = !currentIsInvalid && !currentName.isEmpty && (KnownPlayerNames.isKnown(currentName) || KnownPlayers.canonicalize(currentName) != nil)
                    
                    let finalName: String
                    
                    // 🎯 CAS SPÉCIAL POPULATION COUNT: Le nom est visible clairement sur l'étiquette
                    // Prioriser l'OCR (currentName) car eBay peut retourner une autre carte #500
                    if isPopulationCount && currentIsKnown && !currentIsInvalid {
                        finalName = currentName
                        print("🎯 Population Count detected: Prioritizing OCR name [\(finalName)] over eBay [\(ebayName)]")
                    } else if ebayIsInvalid && currentIsInvalid {
                        // Les deux sont invalides → ne rien mettre
                        finalName = ""
                        print("❌ Both eBay [\(ebayName)] and current [\(currentName)] are invalid phrases")
                    } else if ebayIsInvalid {
                        // eBay invalide mais current OK → garder current
                        finalName = currentName.isEmpty ? "" : currentName
                        print("❌ Rejecting invalid eBay phrase: [\(ebayName)], keeping: [\(finalName)]")
                    } else if currentIsInvalid {
                        // Current invalide mais eBay OK → garder eBay
                        finalName = ebayName
                        print("❌ Rejecting invalid current phrase: [\(currentName)], using eBay: [\(finalName)]")
                    } else if !ebayIsKnown && currentIsKnown {
                        // eBay n'est pas un joueur connu mais le nom actuel l'est → garder le nom actuel
                        finalName = currentName
                        print("✅ Keeping known player: [\(finalName)] instead of unknown eBay result: [\(ebayName)]")
                    } else if currentIsKnown && !currentName.isEmpty && ebayName.lowercased().hasPrefix(currentName.lowercased()) {
                        // Current est dans la base de données ET eBay commence par current (ex: Matt → Matthew)
                        // Prioriser la version officielle de la base de données Upper Deck
                        finalName = currentName
                        print("✅ Keeping official database name: [\(finalName)] instead of eBay variant: [\(ebayName)]")
                    } else if !currentName.isEmpty && currentName.lowercased().hasPrefix(ebayName.lowercased()) && currentName.count > ebayName.count {
                        // Le nom actuel est plus complet et commence par le nom eBay → garder le nom actuel
                        finalName = currentName
                        print("✅ Keeping fuller name: [\(finalName)] instead of truncated eBay result: [\(ebayName)]")
                    } else if !currentName.isEmpty && ebayName.lowercased().hasPrefix(currentName.lowercased()) && ebayName.count > currentName.count {
                        // Le nom eBay est plus complet → utiliser eBay (si current n'est pas dans la base)
                        finalName = ebayName
                        print("✅ Using fuller eBay name: [\(finalName)] instead of [\(currentName)]")
                    } else if !currentName.isEmpty && currentName.count > ebayName.count {
                        // Vérifier si le nom eBay est contenu dans le nom actuel
                        // Ex: "Benoit-Olivier Groulx" contient "Olivier Groulx"
                        let currentWords = currentName.lowercased().replacingOccurrences(of: "-", with: " ").components(separatedBy: " ")
                        let ebayWords = ebayName.lowercased().components(separatedBy: " ")
                        
                        // Vérifier si tous les mots d'eBay sont dans current
                        let allWordsPresent = ebayWords.allSatisfy { ebayWord in
                            currentWords.contains { currentWord in
                                currentWord == ebayWord || currentWord.contains(ebayWord)
                            }
                        }
                        
                        if allWordsPresent {
                            finalName = currentName
                            print("✅ Keeping fuller compound name: [\(finalName)] (contains eBay: [\(ebayName)])")
                        } else {
                            finalName = ebayName
                        }
                    } else {
                        // ⚠️ VÉRIFICATION FINALE: Les noms correspondent-ils?
                        // Comparer les noms mot par mot pour voir s'ils ont des mots en commun
                        let currentWords = Set(currentName.lowercased().components(separatedBy: .whitespaces).filter { $0.count > 2 })
                        let ebayWords = Set(ebayName.lowercased().components(separatedBy: .whitespaces).filter { $0.count > 2 })
                        
                        // Calculer l'intersection (mots en commun)
                        let commonWords = currentWords.intersection(ebayWords)
                        
                        // Si aucun mot en commun ET on a un nom OCR valide, c'est probablement la mauvaise carte
                        if commonWords.isEmpty && !currentName.isEmpty && currentWords.count >= 2 {
                            // 🎯 VALIDATION CROISÉE: Avant de rejeter eBay, vérifier si le nom eBay + le numéro
                            // détecté existent ensemble dans la base locale
                            var shouldUseEbay = false
                            
                            if !cardNumber.isEmpty && cardNumber.contains("-") {
                                // On a un numéro préfixé détecté (ex: DZ-7)
                                // Vérifier si eBay name + ce numéro existe dans la base
                                if let ebayCard = findCardByNumber(
                                    cardNumber: cardNumber,
                                    setName: setName.isEmpty ? nil : setName,
                                    year: cardYear.isEmpty ? nil : cardYear
                                ) {
                                    if let foundPlayer = ebayCard.player, !foundPlayer.isEmpty {
                                        let foundPlayerNormalized = foundPlayer.uppercased()
                                        let ebayNormalized = ebayName.uppercased()
                                        
                                        // Si le joueur trouvé correspond au nom eBay
                                        if foundPlayerNormalized.contains(ebayNormalized) || 
                                           ebayNormalized.contains(foundPlayerNormalized) ||
                                           foundPlayerNormalized == ebayNormalized {
                                            print("✅ CROSS-VALIDATION: eBay name [\(ebayName)] + number [\(cardNumber)] found in database as [\(foundPlayer)]")
                                            shouldUseEbay = true
                                        }
                                    }
                                }
                                
                                // Vérifier aussi si OCR name + ce numéro existe
                                if let ocrCard = findCardByNumber(
                                    cardNumber: cardNumber,
                                    setName: setName.isEmpty ? nil : setName,
                                    year: cardYear.isEmpty ? nil : cardYear
                                ) {
                                    if let foundPlayer = ocrCard.player, !foundPlayer.isEmpty {
                                        let foundPlayerNormalized = foundPlayer.uppercased()
                                        let currentNormalized = currentName.uppercased()
                                        
                                        // Si le joueur trouvé correspond au nom OCR
                                        if foundPlayerNormalized.contains(currentNormalized) || 
                                           currentNormalized.contains(foundPlayerNormalized) ||
                                           foundPlayerNormalized == currentNormalized {
                                            print("✅ CROSS-VALIDATION: OCR name [\(currentName)] + number [\(cardNumber)] found in database as [\(foundPlayer)]")
                                            shouldUseEbay = false  // Garder OCR
                                        }
                                    }
                                }
                            }
                            
                            if shouldUseEbay {
                                finalName = ebayName
                                print("✅ Using eBay name [\(ebayName)] based on cross-validation with card number")
                            } else {
                                // Pas de correspondance du tout → rejeter eBay, garder OCR
                                finalName = currentName
                                print("⚠️ eBay name [\(ebayName)] has NO common words with OCR [\(currentName)] - keeping OCR")
                            }
                        } else {
                            // Utiliser le nom eBay par défaut
                            finalName = ebayName
                        }
                    }
                    
                    if !finalName.isEmpty {
                        // Normaliser en Title Case (Marc Del Gaizo au lieu de MARC DEL GAIZO)
                        let normalizedName = normalizePlayerNameDisplay(finalName)
                        playerName = normalizedName
                        lockedPlayerName = normalizedName  // ðŸ”’ LOCK pour empÃªcher qu'il soit Ã©crasÃ©
                        playerNameRefreshID = UUID() // ðŸ”„ Force le refresh du TextField
                        print("ðŸ”’ Image Search LOCKED playerName to: [\(playerName)]")
                    }
                    }  // Fin du else (playerName pas déjà locké)
                }
                if !result.year.isEmpty {
                    let ebayYear = normalizeYear(result.year)
                    
                    // 🛡️ VALIDATION: Rejeter l'année eBay si elle diffère de plus de 2 ans de l'OCR
                    // Exemple: OCR dit "2025-26", eBay dit "2016-17" → REJETER (différence de 9 ans)
                    if !cardYear.isEmpty {
                        // Extraire les années numériques pour comparaison
                        let ocrYearNum = Int(cardYear.prefix(4)) ?? 0
                        let ebayYearNum = Int(ebayYear.prefix(4)) ?? 0
                        let yearDiff = abs(ocrYearNum - ebayYearNum)
                        
                        if yearDiff > 2 {
                            print("⚠️ Rejecting eBay year [\(ebayYear)]: differs by \(yearDiff) years from OCR year [\(cardYear)]")
                        } else {
                            cardYear = ebayYear
                            print("✅ Accepting eBay year [\(ebayYear)] (within 2 years of OCR)")
                        }
                    } else {
                        // Pas d'année OCR, accepter l'année eBay
                        cardYear = ebayYear
                    }
                }
                if !result.company.isEmpty {
                    companyName = result.company
                }
                if !result.setName.isEmpty {
                    // 🔒 MVP PROTECTION: Si MVP et nom locked, NE PAS écraser le setName avec celui d'eBay
                    if isMVPCard && playerNameLockEnabled {
                        print("🔒 MVP with locked name - ignoring eBay set name [\(result.setName)], keeping [\(setName)]")
                    } else if result.setName.uppercased().contains("YOUNG GUNS") || result.setName.uppercased().contains("YOUNGGUNS") {
                        // ⚠️ VALIDATION: "Young Guns" ne doit être accepté QUE si le numéro est dans la plage correcte
                        // Series 1: 201-250, Series 2: 451-500, Extended Series: 701-730
                        let numToCheck = !cardNumber.isEmpty ? cardNumber : result.cardNumber
                        if let num = Int(numToCheck.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)) {
                            let isValidYG = (201...250).contains(num) || (451...500).contains(num) || (701...730).contains(num)
                            if isValidYG {
                                setName = result.setName
                                print("✅ Young Guns validated: card #\(num) is in valid range")
                            } else {
                                print("⚠️ Rejecting 'Young Guns' set: card #\(num) is outside YG range (201-250, 451-500, 701-730)")
                                setName = ""  // Ignorer ce set, le fallback trouvera le bon
                            }
                        } else {
                            // Pas de numéro détecté, accepter quand même (le fallback corrigera si nécessaire)
                            setName = result.setName
                        }
                    } else {
                        setName = result.setName
                    }
                }
                
                // 🔍 EXTRACTION: Chercher les numéros de carte dans les titres eBay retournés
                // eBay peut retourner un mauvais numéro (comme #13 = numéro de maillot)
                // mais les TITRES contiennent souvent le vrai numéro (ex: "#DZ-7")
                var extractedNumbers: [String] = []
                if !result.debugInfo.isEmpty {
                    // Extraire tous les patterns de numéros: #DZ-7, DZ-7, PC-4, etc.
                    let patterns = [
                        "#([A-Z]{1,3})-?(\\d{1,3})",  // #DZ-7, #PC-4
                        "([A-Z]{1,3})-\\d{1,3}",      // DZ-7, PC-4
                        "#(\\d{1,3})\\b"              // #135
                    ]
                    
                    for pattern in patterns {
                        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                            let matches = regex.matches(in: result.debugInfo, range: NSRange(result.debugInfo.startIndex..., in: result.debugInfo))
                            for match in matches {
                                if let range = Range(match.range, in: result.debugInfo) {
                                    let number = String(result.debugInfo[range])
                                        .replacingOccurrences(of: "#", with: "")
                                        .trimmingCharacters(in: .whitespaces)
                                    // Ne PAS dédupliquer - on veut compter les occurrences!
                                    extractedNumbers.append(number)
                                }
                            }
                        }
                    }
                    
                    if !extractedNumbers.isEmpty {
                        print("🔍 Extracted card numbers from eBay titles: \(extractedNumbers)")
                        
                        // 🚫 FILTRER les numéros avec préfixes d'équipes (WILD-5 = score, pas numéro de carte)
                        let teamPrefixes = ["WILD", "RANGERS", "BRUINS", "LEAFS", "OILERS", "FLAMES", 
                                           "CANADIENS", "JETS", "CANUCKS", "AVALANCHE", "GOLDEN", "DEVILS",
                                           "ISLANDERS", "BLUES", "KINGS", "DUCKS", "SHARKS", "SENATORS",
                                           "SABRES", "RED", "BLUE", "BLACK", "WHITE", "GOLD", "SILVER",
                                           "ILD", "ANGE", "RUIN", "UDC", "THE", "HIS"]
                        
                        let validNumbers = extractedNumbers.filter { number in
                            let prefix = number.uppercased().components(separatedBy: "-").first ?? ""
                            return !teamPrefixes.contains(prefix)
                        }
                        
                        if validNumbers.isEmpty {
                            print("⚠️ All extracted numbers were team names/scores, ignoring: \(extractedNumbers)")
                        } else {
                            print("✅ Valid card numbers after filtering: \(validNumbers)")
                            
                            // 📊 COMPTER les occurrences de chaque numéro
                            var numberCounts: [String: Int] = [:]
                            for num in validNumbers {
                                numberCounts[num, default: 0] += 1
                            }
                            
                            // Trouver le numéro le plus fréquent
                            let mostFrequentNumber = numberCounts.max(by: { $0.value < $1.value })
                            
                            if let (frequentNum, count) = mostFrequentNumber, count >= 3 {
                                // Si un numéro apparaît 3+ fois, il a PRIORITÉ ABSOLUE
                                print("🎯 Number [\(frequentNum)] appears \(count) times in eBay titles - PRIORITY!")
                                
                                // ⚠️ PROTECTION: Si playerName est locké (ex: MVP PRIORITY LOCK),
                                // ne PAS override le cardNumber car joueur+numéro sont liés
                                if playerNameLockEnabled && !cardNumber.isEmpty {
                                    print("🔒 Player name is locked, keeping current number [\(cardNumber)] despite eBay frequency")
                                } else if cardNumber != frequentNum {
                                    print("✅ Overriding current number [\(cardNumber)] with frequent eBay number [\(frequentNum)]")
                                    cardNumber = frequentNum
                                }
                            } else {
                                // Logique normale: priorité aux préfixés
                                let prefixedNumbers = validNumbers.filter { $0.contains("-") }
                                
                                // 🛡️ PROTECTION: Si l'OCR a déjà un numéro préfixé valide, ne pas l'écraser
                                let ocrHasPrefixed = cardNumber.contains("-")
                                
                                if let prefixed = prefixedNumbers.first {
                                    // Si on a trouvé un numéro avec préfixe dans les titres,
                                    // l'utiliser SEULEMENT si l'OCR n'a pas déjà un numéro préfixé
                                    if !ocrHasPrefixed && (result.cardNumber.isEmpty || !result.cardNumber.contains("-")) {
                                        print("✅ Using prefixed number [\(prefixed)] from eBay titles (more specific than [\(result.cardNumber)])")
                                        cardNumber = prefixed
                                    } else if ocrHasPrefixed {
                                        print("🛡️ Keeping OCR prefixed number [\(cardNumber)] instead of eBay [\(prefixed)]")
                                    }
                                } else if result.cardNumber.isEmpty {
                                    // Pas de numéro préfixé trouvé, utiliser le premier numéro simple
                                    if let simpleNumber = validNumbers.first {
                                        print("✅ Using number [\(simpleNumber)] extracted from eBay titles")
                                        cardNumber = simpleNumber
                                    }
                                }
                            }
                        }
                    }
                }
                
                // 🔧 AUTO-CORRECTION DU SET: Maintenant qu'on a le bon numéro (extrait des titres eBay),
                // corriger le set si le numéro a un préfixe de subset
                if !cardNumber.isEmpty {
                    let numUpper = cardNumber.uppercased()
                    if numUpper.hasPrefix("DZ-") && !setName.uppercased().contains("DAZZLERS") {
                        print("🔧 Auto-correcting set: [\(setName)] → [Dazzlers] based on card number [\(cardNumber)]")
                        setName = "Dazzlers"
                    } else if numUpper.hasPrefix("PC-") && !setName.uppercased().contains("POPULATION") {
                        print("🔧 Auto-correcting set: [\(setName)] → [Population Count] based on card number [\(cardNumber)]")
                        setName = "Population Count"
                    } else if numUpper.hasPrefix("CQ-") && !setName.uppercased().contains("CUP") && !setName.uppercased().contains("QUEST") {
                        print("🔧 Auto-correcting set: [\(setName)] → [Cup Quest] based on card number [\(cardNumber)]")
                        setName = "Cup Quest"
                    } else if numUpper.hasPrefix("SR-") && !setName.uppercased().contains("SIZZLE") && !setName.uppercased().contains("REEL") {
                        print("🔧 Auto-correcting set: [\(setName)] → [Sizzle Reel] based on card number [\(cardNumber)]")
                        setName = "Sizzle Reel"
                    } else if numUpper.hasPrefix("FW-") && !setName.uppercased().contains("FUTURE") && !setName.uppercased().contains("WATCH") {
                        print("🔧 Auto-correcting set: [\(setName)] → [Future Watch] based on card number [\(cardNumber)]")
                        setName = "Future Watch"
                    } else if numUpper.hasPrefix("P-") && !setName.uppercased().contains("PORTRAITS") {
                        print("🔧 Auto-correcting set: [\(setName)] → [Portraits] based on card number [\(cardNumber)]")
                        setName = "Portraits"
                    }
                }
                
                // ✅ CORRECTION: Si le set ressemble à un numéro de carte (ex: "DZ-7", "YG-201")
                // C'est probablement une erreur d'eBay → Utiliser comme cardNumber
                if let regex = try? NSRegularExpression(pattern: "^([A-Z]{1,3})-?(\\d{1,3})$", options: []),
                   regex.firstMatch(in: setName, range: NSRange(setName.startIndex..., in: setName)) != nil {
                    print("⚠️ Set name [\(setName)] looks like a card number, using as cardNumber")
                    
                    // Si cardNumber est vide ou invalide, utiliser le set comme numéro
                    if result.cardNumber.isEmpty || result.cardNumber.contains("HIS") {
                        // Ajouter ce numéro aux candidats OCR pour le fallback
                        print("✅ Using set name [\(setName)] as card number")
                    }
                    
                    // Vider le setName pour forcer le fallback à trouver le vrai set
                    setName = ""
                }
                
                // ✅ Si le set est "Series 1" ou "Series 2" et pas de compagnie → Upper Deck
                if companyName.isEmpty && (setName.contains("Series 1") || setName.contains("Series 2")) {
                    companyName = "Upper Deck"
                    print("✅ Inferred company: [Upper Deck] from set name: [\(setName)]")
                }
                
                // ✅ NOUVEAU: Chercher le numéro et le set complet dans la base locale (tcdb_sets.json)
                // Si on trouve une correspondance exacte, utiliser ces infos au lieu de celles d'eBay
                var overriddenNumber: String? = nil
                
                var shouldTryFallback = false
                
                // 🛡️ PROTECTION: Ne pas écraser le numéro si on a déjà un numéro valide de l'OCR
                // MAIS chercher quand même le nom du joueur par numéro si le nom actuel est invalide
                let hasValidOCRNumber = !cardNumber.isEmpty && (
                    cardNumber.contains("-") ||  // Numéro préfixé (DZ-7, PC-4, etc.)
                    ((201...250).contains(Int(cardNumber) ?? 0) || 
                     (451...500).contains(Int(cardNumber) ?? 0) || 
                     (701...730).contains(Int(cardNumber) ?? 0))  // Young Guns range
                )
                
                let playerNameIsInvalid = playerName.isEmpty || 
                    looksLikeBadName(playerName) ||
                    KnownPlayerNames.isKnown(playerName) == false
                
                if hasValidOCRNumber {
                    print("🛡️ Valid OCR number detected: [\(cardNumber)]")
                    
                    // ⚠️ VALIDATION: Vérifier si le numéro OCR existe vraiment dans la base
                    let ocrNumberExists = findCardByNumber(
                        cardNumber: cardNumber,
                        setName: nil,  // Pas de filtre de set - juste vérifier existence
                        year: cardYear.isEmpty ? nil : cardYear
                    ) != nil
                    
                    // Si le numéro OCR n'existe PAS dans la base ET qu'eBay a un numéro différent,
                    // alors le numéro OCR est probablement une erreur (ex: YGR-38 au lieu de 37)
                    if !ocrNumberExists && !result.cardNumber.isEmpty && result.cardNumber != cardNumber {
                        print("⚠️ OCR number [\(cardNumber)] not found in database, but eBay suggests [\(result.cardNumber)]")
                        
                        // Vérifier si le numéro eBay existe dans la base
                        if let ebayCard = findCardByNumber(
                            cardNumber: result.cardNumber,
                            setName: setName.isEmpty ? nil : setName,
                            year: cardYear.isEmpty ? nil : cardYear
                        ) {
                            print("✅ eBay number [\(result.cardNumber)] exists in database - correcting OCR error")
                            cardNumber = cleanCardNumber(result.cardNumber)  // Enlever le # si présent
                            
                            if let foundPlayer = ebayCard.player, !foundPlayer.isEmpty {
                                playerName = normalizePlayerNameDisplay(foundPlayer)
                            }
                            if let localSetName = ebayCard.fullSetName, !localSetName.isEmpty {
                                setName = localSetName
                            }
                        }
                    } else if ocrNumberExists {
                        // Numéro OCR existe, chercher le nom si invalide
                        if playerNameIsInvalid {
                            print("🔍 Looking up player name for card number [\(cardNumber)]...")
                            if let localCard = findCardByNumber(
                                cardNumber: cardNumber,
                                setName: setName.isEmpty ? nil : setName,
                                year: cardYear.isEmpty ? nil : cardYear
                            ) {
                                if let foundPlayer = localCard.player, !foundPlayer.isEmpty {
                                    playerName = normalizePlayerNameDisplay(foundPlayer)
                                    print("✅ Found player name: [\(playerName)] for card [\(cardNumber)]")
                                }
                                if let localSetName = localCard.fullSetName, !localSetName.isEmpty {
                                    setName = localSetName
                                }
                            }
                        }
                    }
                } else if !playerName.isEmpty {
                    // 🔒 MVP PROTECTION: Si MVP et nom locked, NE PAS chercher par nom
                    // Sinon eBay pourrait trouver une autre carte du même joueur
                    if isMVPCard && playerNameLockEnabled {
                        print("🔒 MVP with locked name - skipping local database lookup to prevent override")
                        // Ne rien faire - garder les valeurs OCR
                    } else if let localCard = findCardInLocalDatabase(
                        playerName: playerName,
                        setName: setName.isEmpty ? nil : setName,
                        year: cardYear.isEmpty ? nil : cardYear,
                        detectedCardNumber: cardNumber.isEmpty ? nil : cardNumber
                    ) {
                        // 🛡️ PROTECTION: Si OCR du dos a détecté un numéro, ne JAMAIS l'écraser
                        if !ocrBackCardNumber.isEmpty {
                            print("🛡️ BLOCKING DB override: OCR back already found [\(ocrBackCardNumber)] - ignoring DB number [\(localCard.number ?? "nil")]")
                            // Ne pas utiliser le numéro de la DB - garder celui de l'OCR
                        } else if let localNumber = localCard.number, !localNumber.isEmpty {
                            print("✅ OVERRIDE: Using card number from local database: [\(localNumber)] instead of eBay: [\(result.cardNumber)]")
                            overriddenNumber = localNumber  // On va l'utiliser plus bas
                        }
                        
                        // Utiliser le nom complet du set si disponible
                        if let localSetName = localCard.fullSetName, !localSetName.isEmpty {
                            print("✅ OVERRIDE: Using full set name from local database: [\(localSetName)] instead of eBay: [\(setName)]")
                            setName = localSetName
                        }
                    } else {
                        // Pas trouvé par nom → Essayer le fallback
                        shouldTryFallback = true
                    }
                } else {
                    // playerName vide → Essayer le fallback direct
                    print("⚡ Player name is empty, trying fallback search by card number...")
                    shouldTryFallback = true
                }
                
                if shouldTryFallback {
                    // ⚡ FALLBACK: Si pas trouvé par nom (ex: "Watch Horizontal" invalide), 
                    // essayer de trouver par NUMÉRO de carte
                    
                    // 🎯 Collecter les numéros candidats depuis différentes sources
                    var numberCandidates: [String] = []
                    
                    // 🔍 OPTIMISATION YOUNG GUNS: Détecter si c'est une Young Guns
                    // Sur les Young Guns, le numéro est TOUJOURS en haut à gauche
                    let isYoungGuns = backLines.contains { line in
                        line.range(of: "Young Guns", options: .caseInsensitive) != nil ||
                        line.range(of: "YOUNG GUNS", options: .caseInsensitive) != nil
                    }
                    
                    // PRIORITÉ 1: Extraire les numéros depuis l'OCR de l'arrière
                    let linesToScan: [String]
                    if isYoungGuns {
                        // Pour Young Guns: chercher seulement dans les 5 premières lignes (haut de carte)
                        linesToScan = Array(backLines.prefix(5))
                        print("🎯 Young Guns detected - scanning only top 5 lines for card number")
                    } else {
                        // Pour autres sets: scanner toutes les lignes
                        linesToScan = backLines
                    }
                    
                    let ocrCandidates = extractCardNumberFromOCR(linesToScan)
                    numberCandidates.append(contentsOf: ocrCandidates.map { $0.number })
                    
                    // PRIORITÉ 2: Ajouter le numéro actuel si déjà rempli
                    if !cardNumber.isEmpty && !numberCandidates.contains(cardNumber) {
                        // 🚫 FILTRAGE: Ne pas ajouter si c'est un nom d'équipe
                        let teamNames = ["WILD", "RANGERS", "BRUINS", "LEAFS", "OILERS", "FLAMES", 
                                        "CANADIENS", "JETS", "CANUCKS", "AVALANCHE", "GOLDEN", "DEVILS",
                                        "ISLANDERS", "BLUES", "KINGS", "DUCKS", "SHARKS", "SENATORS",
                                        "SABRES", "RED", "BLUE", "BLACK", "WHITE", "GOLD", "SILVER"]
                        
                        // Extraire le préfixe de cardNumber (ex: "WILD-5" → "WILD")
                        let parts = cardNumber.components(separatedBy: "-")
                        let isTeamName = parts.count > 0 && teamNames.contains(parts[0].uppercased())
                        
                        if !isTeamName {
                            numberCandidates.append(cardNumber)
                            print("📍 Added current card number: [\(cardNumber)]")
                        } else {
                            print("🚫 Skipping team name in cardNumber: [\(cardNumber)]")
                        }
                    }
                    
                    // PRIORITÉ 3: Ajouter le numéro d'eBay (avec filtres)
                    let ebayNum = result.cardNumber.replacingOccurrences(of: "#", with: "")
                    if !ebayNum.isEmpty && !ebayNum.contains("/"),
                       !numberCandidates.contains(ebayNum) {
                        // Filtrer seulement si c'est un numéro simple
                        if let intNum = Int(ebayNum), intNum <= 500 {
                            numberCandidates.append(ebayNum)
                            print("📍 Added eBay number: [\(ebayNum)]")
                        }
                    }
                    
                    // PRIORITÉ 4: Si le set name ressemble à un numéro (ex: "DZ-7")
                    let originalSetName = result.setName
                    if let regex = try? NSRegularExpression(pattern: "^([A-Z]{1,3})-?(\\d{1,3})$", options: []),
                       regex.firstMatch(in: originalSetName, range: NSRange(originalSetName.startIndex..., in: originalSetName)) != nil,
                       !numberCandidates.contains(originalSetName) {
                        
                        // 🚫 FILTRAGE: Ne pas ajouter si c'est un nom d'équipe
                        let teamNames = ["WILD", "RANGERS", "BRUINS", "LEAFS", "OILERS", "FLAMES", 
                                        "CANADIENS", "JETS", "CANUCKS", "AVALANCHE", "GOLDEN", "DEVILS",
                                        "ISLANDERS", "BLUES", "KINGS", "DUCKS", "SHARKS", "SENATORS",
                                        "SABRES", "RED", "BLUE", "BLACK", "WHITE", "GOLD", "SILVER"]
                        
                        let parts = originalSetName.components(separatedBy: "-")
                        let isTeamName = parts.count > 0 && teamNames.contains(parts[0].uppercased())
                        
                        if !isTeamName {
                            numberCandidates.append(originalSetName)
                            print("📍 Added set name as card number: [\(originalSetName)]")
                        } else {
                            print("🚫 Skipping team name in set name: [\(originalSetName)]")
                        }
                    }
                    
                    // 🎯 Extraire le nom du joueur détecté dans l'OCR (pour validation)
                    // Chercher dans les lignes de l'arrière pour des noms en majuscules
                    var detectedPlayerNames: [String] = []
                    let invalidNamePhrases = ["UD PORTRAITS", "NEW YORK", "UPPER DECK", "YOUNG GUNS", 
                                             "FUTURE WATCH", "SP AUTHENTIC", "FLYERS", "RANGERS", "BRUINS",
                                             "LEAFS", "CANADIENS", "SENATORS", "OILERS", "FLAMES", "CANUCKS",
                                             "JETS", "AVALANCHE", "HURRICANES", "BLUE JACKETS", "STARS", 
                                             "WILD", "PREDATORS", "BLUES", "DUCKS", "SHARKS", "KRAKEN",
                                             "GOLDEN KNIGHTS", "COYOTES", "BLACKHAWKS", "RED WINGS", "PANTHERS",
                                             "LIGHTNING", "CAPITALS", "PENGUINS", "DEVILS", "ISLANDERS", "SABRES"]
                    
                    for line in backLines.prefix(15) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        // Chercher des noms avec 2+ mots en majuscules
                        let words = trimmed.split(separator: " ")
                        if words.count >= 2 && words.count <= 4 {
                            let allCaps = words.allSatisfy { $0.allSatisfy { $0.isUppercase || $0.isWhitespace } }
                            if allCaps {
                                let name = words.joined(separator: " ")
                                
                                // 🚫 Filtrer les noms invalides (équipes, sets, etc.)
                                let isInvalid = invalidNamePhrases.contains { phrase in
                                    name.uppercased().contains(phrase)
                                }
                                
                                if !isInvalid && name.count > 5 && name.count < 30 {
                                    detectedPlayerNames.append(name)
                                    print("👤 Detected player name in OCR: [\(name)]")
                                } else if isInvalid {
                                    print("🚫 Ignoring invalid name phrase: [\(name)]")
                                }
                            }
                        }
                    }
                    
                    // 🎯 PRIORISATION: Réorganiser les candidats pour que les numéros préfixés soient en premier
                    // Les numéros préfixés (DZ-7, PC-4) sont plus spécifiques et fiables que les numéros simples (13, 7)
                    let prefixedNumbers = numberCandidates.filter { $0.contains("-") }
                    let simpleNumbers = numberCandidates.filter { !$0.contains("-") }
                    let prioritizedCandidates = prefixedNumbers + simpleNumbers
                    
                    print("🎯 Prioritized candidates: prefixed=\(prefixedNumbers.count), simple=\(simpleNumbers.count)")
                    
                    // 🎯 Essayer chaque candidat de numéro dans l'ordre (préfixés en premier)
                    var foundMatch = false
                    for (index, num) in prioritizedCandidates.enumerated() {
                        print("🔍 Trying candidate #\(index+1): [\(num)]")
                        
                        if let cardByNumber = findCardByNumber(
                            cardNumber: num,
                            setName: setName.isEmpty ? nil : setName,
                            year: cardYear.isEmpty ? nil : cardYear
                        ) {
                            guard let foundPlayer = cardByNumber.player, !foundPlayer.isEmpty else {
                                continue
                            }
                            
                            // ✅ VALIDATION: Vérifier que le nom trouvé correspond au nom détecté
                            var isValidMatch = false
                            
                            // 🎯 EXCEPTION: Si le numéro a un préfixe (P-14, DZ-7, etc.), accepter automatiquement
                            // car ces numéros sont uniques et non-ambigus
                            if num.contains("-") {
                                isValidMatch = true
                                print("✅ Prefixed card number [\(num)] found in database - auto-accepting [\(foundPlayer)]")
                            } else if !detectedPlayerNames.isEmpty {
                                // Comparer avec les noms détectés dans l'OCR
                                let foundPlayerNormalized = foundPlayer.uppercased()
                                let foundPlayerWords = Set(foundPlayerNormalized.split(separator: " ").map { String($0) })
                                
                                for detectedName in detectedPlayerNames {
                                    let detectedNormalized = detectedName.uppercased()
                                    let detectedWords = Set(detectedNormalized.split(separator: " ").map { String($0) })
                                    
                                    // Match si les noms sont identiques
                                    if foundPlayerNormalized == detectedNormalized {
                                        isValidMatch = true
                                        print("✅ Name validation: [\(foundPlayer)] matches detected [\(detectedName)] (exact)")
                                        break
                                    }
                                    
                                    // Match si un nom contient l'autre
                                    if foundPlayerNormalized.contains(detectedNormalized) ||
                                       detectedNormalized.contains(foundPlayerNormalized) {
                                        isValidMatch = true
                                        print("✅ Name validation: [\(foundPlayer)] matches detected [\(detectedName)] (contains)")
                                        break
                                    }
                                    
                                    // Match si tous les mots d'un nom sont dans l'autre
                                    // Ex: "Gabe Perreault" matches ["GABE", "PERREAULT"]
                                    if !foundPlayerWords.isEmpty && !detectedWords.isEmpty {
                                        let commonWords = foundPlayerWords.intersection(detectedWords)
                                        if commonWords.count >= 2 || (commonWords.count >= 1 && foundPlayerWords.count == 1) {
                                            isValidMatch = true
                                            print("✅ Name validation: [\(foundPlayer)] matches detected [\(detectedName)] (word match)")
                                            break
                                        }
                                    }
                                }
                                
                                // Si aucun match direct, vérifier si TOUS les mots du joueur trouvé
                                // sont présents dans la liste complète des noms détectés
                                if !isValidMatch {
                                    var allWordsFound = true
                                    for word in foundPlayerWords {
                                        let wordInDetected = detectedPlayerNames.contains { $0.uppercased().contains(word) }
                                        if !wordInDetected {
                                            allWordsFound = false
                                            break
                                        }
                                    }
                                    if allWordsFound && foundPlayerWords.count >= 2 {
                                        isValidMatch = true
                                        print("✅ Name validation: [\(foundPlayer)] - all words found in detected names")
                                    }
                                }
                                
                                if !isValidMatch {
                                    print("❌ Name mismatch: [\(foundPlayer)] doesn't match any detected names, trying next candidate...")
                                    continue
                                }
                            } else {
                                // Pas de nom détecté dans l'OCR, accepter le premier trouvé
                                isValidMatch = true
                                print("⚠️ No name detected in OCR to validate, accepting [\(foundPlayer)]")
                            }
                            
                            // ✅ Match valide!
                        if isValidMatch {
                            print("✅ FALLBACK SUCCESS: Found player by number: [\(foundPlayer)] for card [\(num)]")
                            
                            // ⚠️ PROTECTION: Ne pas écraser le nom si déjà verrouillé avec haute confiance
                            if let locked = lockedPlayerName, !locked.isEmpty, locked != playerName {
                                print("⚠️ Player name already locked: [\(locked)], not overriding with [\(foundPlayer)]")
                                // Garder le nom verrouillé mais utiliser le numéro trouvé
                            } else {
                                playerName = normalizePlayerNameDisplay(foundPlayer)
                                lockedPlayerName = playerName  // 🔒 LOCK
                                playerNameRefreshID = UUID()
                            }
                            
                            overriddenNumber = num
                            
                            // Utiliser le nom complet du set
                            if let localSetName = cardByNumber.fullSetName, !localSetName.isEmpty {
                                print("✅ OVERRIDE: Using full set name from local database: [\(localSetName)]")
                                setName = localSetName
                            }
                            
                            foundMatch = true
                            break  // Sortir de la boucle, on a trouvé!
                        }
                    }
                }
                
                if !foundMatch {
                    print("❌ No valid card number found after trying \(numberCandidates.count) candidates")
                    
                    // 🆘 DERNIER RECOURS: Si on a un joueur ET un set, chercher directement
                    // Utile pour les cas où le numéro est illisible mais le reste est détecté
                    if !playerName.isEmpty && !setName.isEmpty {
                        print("🆘 Last resort: Searching by player name + set name...")
                        
                        if let localCard = findCardInLocalDatabase(
                            playerName: playerName,
                            setName: setName.isEmpty ? nil : setName,
                            year: cardYear.isEmpty ? nil : cardYear
                        ) {
                            if let localNumber = localCard.number, !localNumber.isEmpty {
                                print("✅ LAST RESORT SUCCESS: Found card by player+set")
                                print("   Player: [\(playerName)]")
                                print("   Number: [\(localNumber)]")
                                print("   Set: [\(localCard.fullSetName ?? setName)]")
                                
                                // 🔒 MVP PROTECTION: Ne pas override si MVP locked
                                if isMVPCard && playerNameLockEnabled && !cardNumber.isEmpty {
                                    print("🔒 MVP locked - keeping OCR number [\(cardNumber)] instead of local [\(localNumber)]")
                                } else {
                                    overriddenNumber = localNumber
                                }
                                
                                if let localSetName = localCard.fullSetName, !localSetName.isEmpty {
                                    // 🔒 MVP PROTECTION: Ne pas override le set non plus
                                    if isMVPCard && playerNameLockEnabled {
                                        print("🔒 MVP locked - keeping OCR set [\(setName)] instead of local [\(localSetName)]")
                                    } else {
                                        setName = localSetName
                                    }
                                }
                                
                                foundMatch = true
                            }
                        }
                    }
                }
            }
                
                if !result.cardNumber.isEmpty || overriddenNumber != nil || !ocrBackCardNumber.isEmpty {
                    // 🛡️ PRIORITÉ ABSOLUE: OCR du dos > base locale > eBay
                    var correctedNumber: String
                    
                    // 🔒 MVP PROTECTION: Si MVP locked ET cardNumber déjà validé, ignorer OCR du dos s'il diffère
                    if !ocrBackCardNumber.isEmpty {
                        let cleanedOcrBack = cleanCardNumber(ocrBackCardNumber)
                        
                        // Vérifier si c'est MVP avec nom locké ET un numéro différent déjà détecté
                        if isMVPCard && playerNameLockEnabled && !cardNumber.isEmpty && cleanedOcrBack != cardNumber {
                            print("🔒 MVP locked - OCR back [\(cleanedOcrBack)] conflicts with validated number [\(cardNumber)] - keeping validated")
                            correctedNumber = cardNumber
                        } else {
                            correctedNumber = cleanedOcrBack
                            print("🛡️ Using OCR back number: [\(correctedNumber)] - PROTECTED")
                        }
                    } else if let dbNum = overriddenNumber {
                        correctedNumber = cleanCardNumber(dbNum)
                        print("📚 Using database number: [\(correctedNumber)]")
                    } else {
                        correctedNumber = cleanCardNumber(result.cardNumber)
                        print("🔍 Using eBay number: [\(correctedNumber)]")
                    }
                    
                    var correctedSetName = setName
                    
                    // 🧹 NETTOYAGE: Retirer le nom du joueur du setName s'il y est
                    // Exemple: "UD Gabe Perreault RC Portraits" → "UD RC Portraits"
                    if !playerName.isEmpty {
                        let playerWords = playerName.lowercased().split(separator: " ")
                        var cleanedSetName = correctedSetName
                        
                        for word in playerWords where word.count > 2 {  // Ignorer "Jr", "II", etc.
                            // Retirer le mot du setName (case insensitive)
                            if let regex = try? NSRegularExpression(pattern: "\\b\(word)\\b", options: .caseInsensitive) {
                                cleanedSetName = regex.stringByReplacingMatches(
                                    in: cleanedSetName,
                                    range: NSRange(cleanedSetName.startIndex..., in: cleanedSetName),
                                    withTemplate: ""
                                )
                            }
                        }
                        
                        // Nettoyer les espaces multiples
                        cleanedSetName = cleanedSetName.replacingOccurrences(of: "  ", with: " ")
                                                       .trimmingCharacters(in: .whitespaces)
                        
                        if cleanedSetName != correctedSetName {
                            print("🧹 Cleaned player name from setName: [\(correctedSetName)] → [\(cleanedSetName)]")
                            correctedSetName = cleanedSetName
                        }
                    }
                    
                    // 🔍 CORRECTION: Pour les Population Count, le vrai numéro est "PC-X", pas "#500"
                    // Vérifier si N'IMPORTE QUEL titre eBay mentionne "Population Count"
                    let hasPopulationCount = result.debugInfo.range(of: "Population Count", options: .caseInsensitive) != nil
                    
                    if hasPopulationCount {
                        print("🔍 Detected Population Count card, correcting number and set...")
                        
                        // STRATÉGIE PRIORITAIRE: Extraire le numéro de série de l'OCR du FRONT de la carte
                        // La carte affiche "2025-26 UPPER DECK SERIES 1" ou "SERIES 2" en haut
                        var seriesNumber = "1" // Par défaut Series 1
                        
                        // 1️⃣ Chercher d'abord dans l'OCR du front (plus fiable)
                        for line in frontLines {
                            if line.range(of: "SERIES", options: .caseInsensitive) != nil,
                               let regex = try? NSRegularExpression(pattern: "SERIES\\s*(\\d+)", options: .caseInsensitive),
                               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                               let numRange = Range(match.range(at: 1), in: line) {
                                seriesNumber = String(line[numRange])
                                print("✅ Found series number: \(seriesNumber) from front OCR: [\(line)]")
                                break
                            }
                        }
                        
                        // 2️⃣ Si pas trouvé dans OCR, fallback vers titres eBay
                        if seriesNumber == "1" && !frontLines.contains(where: { $0.range(of: "SERIES", options: .caseInsensitive) != nil }) {
                            let lines = result.debugInfo.components(separatedBy: "\n")
                            let playerNameWords = playerName.lowercased().components(separatedBy: " ")
                            
                            // Chercher dans le PREMIER titre qui contient Population Count ET le nom du joueur
                            for line in lines {
                                if line.range(of: "Population Count", options: .caseInsensitive) != nil {
                                    let lineWords = line.lowercased()
                                    let hasPlayerName = playerNameWords.count >= 2 && 
                                                       playerNameWords.allSatisfy { word in lineWords.contains(word) }
                                    
                                    if hasPlayerName {
                                        if let regex = try? NSRegularExpression(pattern: "Series\\s*(\\d+)", options: .caseInsensitive),
                                           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                                           let numRange = Range(match.range(at: 1), in: line) {
                                            seriesNumber = String(line[numRange])
                                            print("✅ Found series number: \(seriesNumber) in eBay title with player name")
                                            break // Arrêter au premier match avec le nom du joueur
                                        }
                                    }
                                }
                            }
                        }
                        
                        // Corriger le setName: "Series X" (pas Young Guns)
                        correctedSetName = "Series \(seriesNumber)"
                        print("✅ Corrected setName from [\(setName)] to [\(correctedSetName)]")
                        
                        // Chercher le numéro PC-X si nécessaire
                        if !correctedNumber.uppercased().hasPrefix("PC-") {
                            // 1️⃣ Chercher d'abord dans l'OCR du front (visible sur la carte)
                            for line in frontLines {
                                if let regex = try? NSRegularExpression(pattern: "PC[-\\s]?(\\d{1,2})", options: .caseInsensitive),
                                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                                   let numberRange = Range(match.range(at: 1), in: line) {
                                    let pcNumber = String(line[numberRange])
                                    correctedNumber = "PC-\(pcNumber)"
                                    print("✅ Corrected Population Count number from front OCR: [\(correctedNumber)]")
                                    break
                                }
                            }
                            
                            // 2️⃣ Si pas trouvé, chercher dans les titres eBay
                            if correctedNumber == result.cardNumber {
                                let lines = result.debugInfo.components(separatedBy: "\n")
                                for line in lines {
                                    // Chercher "#PC-4" ou "PC-4" ou "#PC4" ou "PC4" ou "PC 4"
                                    if let regex = try? NSRegularExpression(pattern: "#?PC[-\\s]?(\\d{1,2})", options: .caseInsensitive),
                                       let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                                       let numberRange = Range(match.range(at: 1), in: line) {
                                        let pcNumber = String(line[numberRange])
                                        correctedNumber = "PC-\(pcNumber)"
                                        print("✅ Corrected Population Count number from eBay: [\(correctedNumber)]")
                                        break
                                    }
                                }
                            }
                            
                            if correctedNumber == result.cardNumber {
                                print("⚠️ Could not find PC-X anywhere, keeping: [\(correctedNumber)]")
                            }
                        }
                    }
                    
                    // 🎯 DÉTECTION GÉNÉRIQUE DES INSERTS/SUBSETS
                    // Liste des inserts courants Upper Deck (en ordre de fréquence)
                    let knownInserts = [
                        "Young Guns",      // Déjà géré par formatSetName()
                        "Population Count", // Déjà géré ci-dessus
                        "Outburst",
                        "High Gloss",
                        "Clear Cut",
                        "UD Canvas",
                        "Portraits",
                        "Exclusives",
                        "Overtime",
                        "Future Watch"
                    ]
                    
                    // Vérifier si un insert est mentionné dans les titres eBay ou l'OCR du dos
                    var detectedInsert: String? = nil
                    
                    // 1️⃣ Chercher dans les titres eBay
                    for insert in knownInserts {
                        if result.debugInfo.range(of: insert, options: .caseInsensitive) != nil {
                            detectedInsert = insert
                            print("🎯 Detected insert from eBay: [\(insert)]")
                            break
                        }
                    }
                    
                    // 2️⃣ Si pas trouvé, chercher dans l'OCR du dos
                    if detectedInsert == nil {
                        let backText = backLines.joined(separator: " ")
                        for insert in knownInserts {
                            if backText.range(of: insert, options: .caseInsensitive) != nil {
                                detectedInsert = insert
                                print("🎯 Detected insert from back OCR: [\(insert)]")
                                break
                            }
                        }
                    }
                    
                    // Ajouter l'insert au setName si détecté (sauf Population Count déjà géré)
                    // 🔒 PROTECTION: Si MVP avec nom locké, ne PAS modifier le setName
                    if let insert = detectedInsert, insert != "Population Count" {
                        if isMVPCard && playerNameLockEnabled {
                            print("🔒 MVP with locked name - ignoring detected insert [\(insert)] from eBay/OCR")
                        } else {
                            // Format: "UD Series 1 Young Guns" ou "UD Series 1 Outburst"
                            // Toujours ajouter si pas déjà présent (même si setName est court type "UD")
                            
                            // ⚠️ EXCEPTION: Ne jamais ajouter "Young Guns" à des sets non-flagship
                            // Young Guns existe SEULEMENT dans Upper Deck flagship (Series 1/2)
                            let setNameLower = correctedSetName.lowercased()
                            
                            // Bloquer explicitement les sets Upper Deck qui ne sont PAS flagship
                            let isNonFlagshipSet = setNameLower.contains("mvp") || 
                                                  setNameLower.contains("allure") || 
                                                  setNameLower.contains("artifacts") ||
                                                  setNameLower.contains("o-pee-chee") ||
                                                  setNameLower.contains("opc") ||
                                                  setNameLower.contains("black diamond") ||
                                                  setNameLower.contains("sp authentic") ||
                                                  setNameLower.contains("portraits")
                            
                            // Young Guns OK si : (Series 1/2) OU (Upper Deck sans autre nom de produit)
                            let isFlagshipSet = (setNameLower.contains("series") || 
                                               (setNameLower.contains("upper deck") && !isNonFlagshipSet) ||
                                               (setNameLower == "ud"))
                            
                            let canAddYoungGuns = insert != "Young Guns" || isFlagshipSet
                            
                            if canAddYoungGuns && !correctedSetName.lowercased().contains(insert.lowercased()) {
                                if correctedSetName.isEmpty {
                                    correctedSetName = insert
                                } else {
                                    correctedSetName = "\(correctedSetName) \(insert)"
                                }
                                print("✅ Added insert to setName: [\(correctedSetName)]")
                            } else if !canAddYoungGuns {
                                print("⚠️ Skipping 'Young Guns' insert for non-UD set: [\(correctedSetName)]")
                            }
                        }
                    }
                    
                    // 🛡️ PROTECTION FINALE: Ne pas écraser cardNumber s'il est déjà valide de l'OCR
                    let currentNumberValid = !cardNumber.isEmpty && (
                        cardNumber.contains("-") ||  // Préfixé (DZ-7, PC-4, etc.)
                        ((201...250).contains(Int(cardNumber) ?? 0) || 
                         (451...500).contains(Int(cardNumber) ?? 0) || 
                         (701...730).contains(Int(cardNumber) ?? 0))  // Young Guns ranges
                    )
                    
                    if currentNumberValid && cardNumber != correctedNumber {
                        print("🛡️ Keeping OCR number [\(cardNumber)] instead of eBay/database [\(correctedNumber)]")
                    } else {
                        cardNumber = cleanCardNumber(correctedNumber)
                    }
                    setName = correctedSetName
                }
                
                let confidencePercent = Int(result.confidence * 100)
                imageSearchStatus = "✅ Carte identifiée (\(confidencePercent)% confiance)"
                ebayDebugStatus = "Image Search: Trouvé! (\(confidencePercent)%)"
                
                // Afficher les titres dans le debug
                ebayDebugTitles = result.debugInfo.components(separatedBy: "\n")
                } else {
                    // Résultats eBay rejetés à cause d'une année incohérente
                    imageSearchStatus = "⚠️ Résultats eBay rejetés (année incohérente)"
                    ebayDebugStatus = "Image Search: Année incompatible avec OCR"
                }
            } else {
                imageSearchStatus = "âš ï¸ Aucune correspondance fiable trouvÃ©e"
                ebayDebugStatus = "Image Search: Pas de rÃ©sultats"
            }
            
        } catch let error as NSError {
            // Gestion des erreurs spÃ©cifiques
            if error.domain == "EbayImageSearch" {
                if error.code == 401 {
                    imageSearchStatus = "âŒ Token eBay expirÃ© - vÃ©rifiez vos credentials"
                    ebayDebugStatus = "Erreur: Token invalide ou expirÃ©"
                } else if error.code == 5 {
                    imageSearchStatus = "âŒ Aucun rÃ©sultat trouvÃ© sur eBay"
                    ebayDebugStatus = "Image Search: 0 rÃ©sultats"
                } else {
                    imageSearchStatus = "âŒ Erreur: \(error.localizedDescription)"
                    ebayDebugStatus = "Erreur Image Search: \(error.localizedDescription)"
                }
            } else {
                imageSearchStatus = "âŒ Erreur rÃ©seau"
                ebayDebugStatus = "Erreur: \(error.localizedDescription)"
            }
        }
        
        // 🔍 VALIDATION CROISÉE FINALE: Vérifier que le nom + numéro correspondent dans la base
        // Cette validation s'exécute APRÈS toutes les sources (OCR + eBay)
        performFinalCrossValidation()
        
        isImageSearching = false
    }

        // MARK: Save



        // MARK: Final sanitizers

        /// Prevents common OCR mixups where the set/insert name (e.g. "Young Guns", "Encore") is used as the player name,
        /// and removes trailing position codes (e.g. "LW", "C", "RW", etc.).
    func sanitizedPlayerName(_ raw: String, allowSingleWord: Bool = false) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // Cyrillic garbage appears often in OCR outputs; never treat it as a player name.
        if containsCyrillic(trimmed) { return nil }
        // Rule #1: ASCII/Latin only (reject other scripts even if they aren't Cyrillic)
        if !isAsciiOrLatinOnly(trimmed) { return nil }

        func alphaKey(_ s: String) -> String {
            let up = s.uppercased()
            let letters = up.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            return String(String.UnicodeScalarView(letters))
    }

        // Normalize separators
        let candidate = trimmed
            .replacingOccurrences(of: "â€¢", with: " ")
            .replacingOccurrences(of: "Â·", with: " ")
            .replacingOccurrences(of: "Â®", with: " ")
            .replacingOccurrences(of: "â„¢", with: " ")
            .replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "  ", with: " ")

        // Remove common OCR junk + team words that often get appended to names (ex: "lues", "blues")
        let deny: Set<String> = [
                    "TRACKING", "SYSTEMS", "TRACKING SYSTEMS",
            "U-PICK", "UPICK", "U PICK",
        // Positions
            "C","LW","RW","LD","RD","G","F","D",
            // Team fragments / common OCR artefacts
            "BLUES","LUES","ILUES","BLOES","BLU ES".replacingOccurrences(of: " ", with: ""),
            // Generic words on backs
            "BORN","HEIGHT","WEIGHT","SHOOTS","RIGHT","LEFT","NHLPA","YEAR","TEAM","SEASON","SEASONS",
            // Countries / cities that often appear in bios and should never become player names
            "AUSTRIA","FELDKIRCH",
            // Company / set words that can leak into name
            "UPPER","DECK","SERIES","YOUNG","GUNS","ROOKIE","RC","HOCKEY","NHL",
                // NHL cities / teams (ban from player name)
                "ANAHEIM",
                "ANGELES",
                "AVALANCHE",
                "BAY",
                "BLACKHAWKS",
                "BLUE",
                "BOSTON",
                "BRUINS",
                "BUFFALO",
                "CALGARY",
                "CANUCKS",
                "CAPITALS",
                "CAROLINA",
                "CHICAGO",
                "COLORADO",
                "COLUMBUS",
                "DALLAS",
                "DETROIT",
                "DEVILS",
                "DUCKS",
                "EDMONTON",
                "FLAMES",
                "FLORIDA",
                "FLYERS",
                "HURRICANES",
                "ISLANDERS",
                "JACKETS",
                "JERSEY",
                "JETS",
                "KINGS",
                "KRAKEN",
                "LEAFS",
                "LOS",
                "MAPLE",
                "MINNESOTA",
                "MONTREAL",
                "NASHVILLE",
                "NEW",
                "OILERS",
                "OTTAWA",
                "PANTHERS",
                "PENGUINS",
                "PHILADELPHIA",
                "PITTSBURGH",
                "PREDATORS",
                "RANGERS",
                "RED",
                "SABRES",
                "SAN",
                "SEATTLE",
                "SENATORS",
                "SHARKS",
                "ST",
                "STARS",
                "TAMPA",
                "TORONTO",
                "UTAH",
                "VANCOUVER",
                "VEGAS",
                "WASHINGTON",
                "WILD",
                "WINGS",
                "WINNIPEG",
                "ANAHEIM",
                "BUFFALO",
                "CALGARY",
                "CAROLINA",
                "COLORADO",
                "COLUMBUS",
                "DALLAS",
                "EDMONTON",
                "FLORIDA",
                "LOS",
                "ANGELES",
                "MINNESOTA",
                "MONTREAL",
                "NASHVILLE",
                "NEW",
                "JERSEY",
                "OTTAWA",
                "PHILADELPHIA",
                "PITTSBURGH",
                "SAN",
                "SEATTLE",
                "ST",
                "LOUIS",
                "TAMPA",
                "BAY",
                "TORONTO",
                "UTAH",
                "VANCOUVER",
                "VEGAS",
                "WASHINGTON"
            ,
            "FUTURE"
        ,
            "WATCH"
        ,
            "FUTUREWATCH"
        ,
            "FUTUREWAT"
        ,
            "ICI"
        ,
            "SP"
        ,
            "AUTHENTIC"
        ]

        let rawParts = candidate
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { String($0).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var parts: [String] = []
        for p in rawParts {
            if containsCyrillic(p) { continue }
            if !isAsciiOrLatinOnly(p) { continue }
            let k = alphaKey(p)
            if k.isEmpty { continue }
            if k.count == 1 { continue } // single-letter noise ("G", etc.)
            if deny.contains(k) { continue }
            parts.append(p)
    }

        // Build candidates from contiguous windows (3-word first, then 2-word).
            // This fixes cases where OCR returns: "Filip Gustavsson Minnesota Wild" (we want "Filip Gustavsson"),
            // and still supports true 3-word names like "Marc Del Gaizo".
            var candidates: [String] = []

            // Prefer 3-word windows if available
            if parts.count >= 3 {
                for i in 0...(parts.count - 3) {
                    candidates.append(parts[i..<i+3].joined(separator: " "))
                }
            }
            // Then 2-word windows
            if parts.count >= 2 {
                for i in 0...(parts.count - 2) {
                    candidates.append(parts[i..<i+2].joined(separator: " "))
                }
            }
            // Optionally allow single-word names
            if allowSingleWord && parts.count >= 1 {
                candidates.append(parts[0])
            }

            // Prefer candidates that look like proper names (Title Case) to avoid teams/sets.
            func looksLikeName(_ s: String) -> Bool {
                let ws = s.split(separator: " ")
                guard ws.count >= 2 else { return false }
                for w in ws {
                    guard let first = w.first else { return false }
                    if !first.isUppercase { return false }
                    // Reject if contains digits or punctuation-heavy tokens
                    if w.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil { return false }
                }
                return true
            }

            // First pass: Known player names that also look like a name
            for cand in candidates {
                if looksLikeName(cand) {
                    // Check both the bundled file list AND the hardcoded list
                    if KnownPlayers.canonicalize(cand) != nil || KnownPlayerNames.isKnown(cand) {
                        // Prefer the canonical form from KnownPlayers if available
                        return KnownPlayers.canonicalize(cand) ?? cand
                    }
                }
            }

            // Second pass: any known player name (some names contain odd casing in OCR)
            for cand in candidates {
                // Check both lists
                if let canonical = KnownPlayers.canonicalize(cand) {
                    return canonical
                }
                if KnownPlayerNames.isKnown(cand) {
                    return cand
                }
            }

            return nil
    }

        /// Convenience wrapper returning a non-optional string.
    func sanitizePlayerName(_ raw: String, allowSingleWord: Bool = false) -> String {
            sanitizedPlayerName(raw, allowSingleWord: allowSingleWord) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

        // âœ… For display/storage: avoid repeating the company name inside the set field.
        func normalizeSetName(company: String, rawSetName: String) -> String {
            var s = rawSetName.trimmingCharacters(in: .whitespacesAndNewlines)
            let c = company.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if c == "upper deck" {
                // Remove leading "Upper Deck " if present.
                let prefix = "upper deck "
                if s.lowercased().hasPrefix(prefix) {
                    s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // Normalize spacing
            s = s.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return s
    }



    func inferPlayerNameFromBackLines(_ lines: [String]) -> String? {
        // Look for the best "FIRST LAST" candidate in raw OCR lines (back side).
        // This is a safety net for cases where the structured back parser misses an obvious name line.
        var best: String? = nil
        var bestScore: Int = -1

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if containsCyrillic(line) { continue }
            if !isAsciiOrLatinOnly(line) { continue }

            // Ignore lines with digits (card #, years, stats)
            if line.rangeOfCharacter(from: .decimalDigits) != nil { continue }

            // Try sanitize (handles city/team/position bans)
            if let candidate = sanitizedPlayerName(line, allowSingleWord: false) {
                // Basic plausibility: 2-4 words, each >= 2 chars
                let parts = candidate.split(separator: " ").map(String.init)
                if parts.count < 2 || parts.count > 4 { continue }
                if parts.contains(where: { $0.count < 2 }) { continue }

                // Score: prefer longer names / more complete
                let score = parts.count * 50 + candidate.count
                if score > bestScore {
                    bestScore = score
                    best = candidate
                }
            }
    }

        return best
    }



    func save() {
            // Reset any previous error
            saveErrorMessage = nil

            isWorking = true
            defer { isWorking = false }

            let cleanOwnerId = ownerId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanOwnerId.isEmpty else {
                saveErrorMessage = "Impossible dâ€™enregistrer : ownerId est vide."
                showSaveErrorAlert = true
                return
            }

            let title = playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Carte" : playerName.trimmingCharacters(in: .whitespacesAndNewlines).properCapitalized()

            let item = CardItem(
                ownerId: cleanOwnerId,
                title: title,
                notes: nil,
                frontImageData: frontImageData,
                backImageData: backImageData,
                estimatedPriceCAD: nil,
                playerName: playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : playerName.trimmingCharacters(in: .whitespacesAndNewlines).properCapitalized(),
                cardYear: cardYear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cardYear.trimmingCharacters(in: .whitespacesAndNewlines),
                companyName: companyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : companyName.trimmingCharacters(in: .whitespacesAndNewlines),
                setName: setName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : setName.trimmingCharacters(in: .whitespacesAndNewlines),
                cardNumber: cardNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cardNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            modelContext.insert(item)

            do {
                // âœ… Important: force a save so the item is persisted immediately
                try modelContext.save()

                // Debug: if you see nothing in "Ma collection", it's almost always a predicate mismatch on ownerId.
                print("✅ CVPhotoOCRAddCardView saved CardItem id=\(item.id) ownerId=\(item.ownerId) title=\(item.title)")

                // 💾 DÉSACTIVÉ: ReferenceImageStore supprimé
                // if let frontImage = frontUIImage, !setName.isEmpty, !cardNumber.isEmpty {
                //     ReferenceImageStore.shared.saveReferenceImage(
                //         frontImage,
                //         setName: setName,
                //         cardNumber: cardNumber,
                //         year: cardYear.isEmpty ? nil : cardYear
                //     )
                // }
                
                // 📤 UPLOAD FIREBASE: Maintenant que les données sont validées/corrigées
                Task {
                    await uploadScanToFirebase(item: item)
                }

                allowDismiss = true
                dismiss()
            } catch {
                // Rollback the inserted object to avoid a ghost item in memory
                modelContext.delete(item)

                saveErrorMessage = "Erreur lors de lâ€™enregistrement : \(error.localizedDescription)"
                showSaveErrorAlert = true

                print("âŒ CVPhotoOCRAddCardView save error: \(error)")
            }
    }

    // MARK: eBay soft correction (optional)

    fileprivate enum EbaySoftCorrector {
        // eBay App ID (Client ID). We accept EBAY_CLIENT_ID from Info.plist (same value used as AppID for Finding API).
        private static var appID: String {
        // We accept either EBAY_CLIENT_ID (preferred) or EBAY_APP_ID for backward compatibility.
        let client = (InfoPlist.string("EBAY_CLIENT_ID") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !client.isEmpty { return client }

        let app = (InfoPlist.string("EBAY_APP_ID") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return app
    }


static var proxyBaseURL: URL? {
    let raw = (Bundle.main.object(forInfoDictionaryKey: "EBAY_PROXY_BASE_URL") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CARDIA_EBAY_PROXY_URL") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "EBAY_PROXY_URL") as? String)
    let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    // Accept both with/without trailing slash
    let cleaned = s.hasSuffix("/") ? String(s.dropLast()) : s
    return URL(string: cleaned)
    }

private static var isConfigured: Bool {
    // Either proxy is configured, or legacy Finding AppID is present.
    return proxyBaseURL != nil || !appID.isEmpty
    }


    // Terms that pollute hockey-card searches on eBay (e.g., "U-Pick / Pick your player" lots)
    private static let ebayNoisePhrases: [String] = [
        "U-PICK", "UPICK", "U PICK",
        "PICK YOUR PLAYER", "PICK A PLAYER", "CHOOSE YOUR PLAYER", "YOU PICK", "PICK EM", "PICK 'EM",
        "PICK FROM", "PICK LIST"
    ]

    private static func cleanEbayQuery(_ raw: String) -> String {
        var q = raw
        q = q.replacingOccurrences(of: "â€“", with: "-")
        q = q.replacingOccurrences(of: "â€”", with: "-")
        q = q.replacingOccurrences(of: "â€‘", with: "-") // nonâ€‘breaking hyphen
        q = q.replacingOccurrences(of: "â€™", with: "'")

        for phrase in ebayNoisePhrases {
        q = q.replacingOccurrences(of: phrase, with: " ", options: [.caseInsensitive])
    }

        q = q
        .replacingOccurrences(of: #"[\s]+"#, with: " ", options: String.CompareOptions.regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return q
    }

    
    private static func normalizedForNoiseMatch(_ s: String) -> String {
        // Normalize common unicode punctuation so our noise filters catch "Uâ€‘Pick", "Uâ€“Pick", etc.
        var t = s.uppercased()
        t = t.replacingOccurrences(of: "â€“", with: "-")
        t = t.replacingOccurrences(of: "â€”", with: "-")
        t = t.replacingOccurrences(of: "â€‘", with: "-") // nonâ€‘breaking hyphen
        t = t.replacingOccurrences(of: "â€’", with: "-")
        t = t.replacingOccurrences(of: "âˆ’", with: "-")
        t = t.replacingOccurrences(of: "â€™", with: "'")
        t = t.replacingOccurrences(of: "â€œ", with: "")
        t = t.replacingOccurrences(of: "â€", with: "")

        // Collapse whitespace
        t = t.replacingOccurrences(of: #"[\s]+"#, with: " ", options: String.CompareOptions.regularExpression)

        // Remove remaining punctuation so "U-Pick!", "U Pick", "Uâ€¢Pick" all normalize similarly.
        t = t.replacingOccurrences(of: #"[^A-Z0-9 ]+"#, with: "", options: String.CompareOptions.regularExpression)

        return t
    }

    private static func filterNoiseTitles(_ titles: [String]) -> [String] {
        guard !titles.isEmpty else { return [] }

        return titles.filter { raw in
        let up = normalizedForNoiseMatch(raw)

        for phrase in ebayNoisePhrases {
            let p = normalizedForNoiseMatch(phrase)
            if up.contains(p) { return false }
    }
        return true
    }
    }
        /// Auto-corrects the player name (and optionally the set prefix) using eBay search titles.
    /// Important: This is "soft" â€” it only applies when confidence is strong.
    struct NameSuggestion {
        let name: String
        let confidence: Double
        let titleMatched: String?
        let titles: [String]
        /// Liste des requÃªtes tentÃ©es (dans l'ordre). Utile pour le debug UI.
        let triedQueries: [String]
        /// La requÃªte qui a rÃ©ellement retournÃ© des titres (si applicable).
        let queryUsed: String?
    }

    /// âœ… VÃ©rifie sur eBay et retourne (nom, confiance, titre) mÃªme si on ne remplace pas automatiquement.
    static func buildSearchQueries(year: String, company: String, set: String, cardNumber: String) -> [String] {
        // Objectif: maximiser les chances de match sur eBay en gardant les infos "fiables"
        // et en relaxant progressivement la requÃªte.
        //
        // 1) RequÃªte la plus prÃ©cise (company + year + set + #number)
        // 2) RequÃªte sans le set complet, mais en gardant un "mot-clÃ© fort" (ex: Young Guns)
        // 3) RequÃªte minimale (company + year + #number)
        let c = company.trimmingCharacters(in: .whitespacesAndNewlines)
        let y = year.trimmingCharacters(in: .whitespacesAndNewlines)

        // CRITICAL: Validate set before using it
        // OCR often produces garbage like "U Asyeu", "Tors'Â·I W" which return 0 results on eBay
        // Better to ignore invalid sets and search without them
        func isValidSet(_ s: String) -> Bool {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return false }
            if trimmed.count < 3 { return false }
            
            // Reject sets with strange characters
            let allowedChars = CharacterSet.alphanumerics.union(CharacterSet.whitespaces).union(CharacterSet(charactersIn: "-"))
            if trimmed.rangeOfCharacter(from: allowedChars.inverted) != nil { return false }
            
            // Known good patterns
            let upper = trimmed.uppercased()
            if upper.contains("YOUNG GUNS") { return true }
            if upper.contains("SERIES") { return true }
            if upper.contains("E-X") || upper.contains("EX") { return true }
            if upper.contains("SP AUTHENTIC") || upper.contains("AUTHENTIC") { return true }
            if upper.contains("EXCLUSIVES") || upper.contains("CANVAS") { return true }
            
            // If set contains numbers (like "2000", "S1", etc), it's probably valid
            if trimmed.rangeOfCharacter(from: .decimalDigits) != nil { return true }
            
            // If it's 2+ normal-looking words (each 3+ chars), keep it
            let words = trimmed.split(separator: " ").map(String.init)
            if words.count >= 2 && words.allSatisfy({ $0.count >= 3 }) { return true }
            
            // Single word with 5+ chars might be valid (like "Exclusives", "Canvas")
            if words.count == 1 && words[0].count >= 5 { return true }
            
            return false
        }
        
        // Use set only if it looks valid, otherwise empty string
        let setToUse = isValidSet(set) ? set : ""

        // Nettoyage du set: on enlÃ¨ve les tirets et on compresse les espaces.
        let setClean = setToUse
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "â€”", with: " ")
        .replacingOccurrences(of: "â€“", with: " ")
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        // Un "mot-clÃ© fort" (souvent plus stable que le libellÃ© complet du set)
        // On privilÃ©gie Young Guns, sinon on prend 2-3 derniers mots du set.
        let lowerSet = setClean.lowercased()
        var strongKeyword = ""
        if lowerSet.contains("young guns") {
        strongKeyword = "Young Guns"
        } else {
        let parts = setClean.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.count >= 2 {
            strongKeyword = parts.suffix(3).joined(separator: " ")
        } else {
            strongKeyword = setClean
    }
    }

        // Normalise le numÃ©ro: on garde le # pour coller aux usages eBay, mais sans doubler.
        let n = cardNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let numberToken = n.isEmpty ? "" : (n.hasPrefix("#") ? n : "#\(n)")

        func make(_ parts: [String]) -> String {
        parts
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

        let q1 = make([c, y, setClean, numberToken])
        let q2 = make([c, y, strongKeyword, numberToken])
        let q3 = make([c, y, numberToken])

        // On retire les doublons en conservant l'ordre
        var seen: Set<String> = []
        var out: [String] = []
        for q in [q1, q2, q3] {
        if q.isEmpty { continue }
        if !seen.contains(q) {
            seen.insert(q)
            out.append(q)
    }
    }
        return out
    }

    /// âœ… VÃ©rifie sur eBay et retourne (nom, confiance, titre) mÃªme si on ne remplace pas automatiquement.
    static func playerNameSuggestion(
        year: String,
        company: String,
        set: String,
        cardNumber: String,
        currentPlayerName: String
    ) async -> NameSuggestion? {

        let queries = buildSearchQueries(year: year, company: company, set: set, cardNumber: cardNumber)

// âœ… Preferred: call backend proxy once with multiple candidate queries.
if let base = proxyBaseURL {
    let market = (findingGlobalId == "EBAY-ENCA") ? "CA" : "US"
    if let (titles, qUsed, tried, _, _, _, _) = try? await proxySuggest(
        base: base,
        queries: queries,
        market: market,
        limit: 25,
        soldOnly: false
    ), !titles.isEmpty {
        let filteredTitles = filterNoiseTitles(titles)
        guard !filteredTitles.isEmpty else { return nil }
        guard let best = bestPlayerName(from: filteredTitles, minCount: 1) else { return nil }
        let cleaned = sanitizePlayerName(best)
        guard !cleaned.isEmpty else { return nil }

        let ocr = sanitizeNameForComparison(currentPlayerName)
        let ebay = sanitizeNameForComparison(cleaned)

        let confidence: Double
        if ocr.isEmpty {
        confidence = 1.0
        } else {
        confidence = normalizedSimilarity(ocr, ebay)
        
        // CRITICAL: If OCR detected a valid-looking name (2 words, capitalized),
        // and eBay suggests something COMPLETELY different (similarity < 0.3),
        // REJECT the eBay suggestion - it's likely a false positive
        let ocrWords = currentPlayerName.split(separator: " ").map(String.init)
        let looksLikeValidOCR = ocrWords.count >= 2 
                             && ocrWords.allSatisfy { $0.first?.isUppercase == true && $0.count >= 2 }
        
        if looksLikeValidOCR && confidence < 0.3 {
            // OCR detected a valid name, but eBay is suggesting something completely different
            // This is likely a false positive (e.g. "Olen Zellweger" OCR vs "Zenon Konopka" eBay)
            return nil
        }
    }

        let display = normalizePlayerNameDisplay(cleaned)
        let lowerDisplay = display.lowercased()
        let titleMatched = filteredTitles.first(where: { $0.lowercased().contains(lowerDisplay) })

        return NameSuggestion(
        name: display,
        confidence: confidence,
        titleMatched: titleMatched,
        titles: filteredTitles,
        triedQueries: tried,
        queryUsed: qUsed ?? (tried.first ?? "")
        )
    }
    }

// Fallback (legacy): multiple direct Finding calls (may be rate-limited).
var titles: [String] = []
var queryUsed: String? = nil

for q in queries {
    if let sold = try? await searchItemTitles(query: q, limit: 12, soldOnly: true), !sold.isEmpty {
        titles = sold
        queryUsed = q
        break
    }
    if let active = try? await searchItemTitles(query: q, limit: 12, soldOnly: false), !active.isEmpty {
        titles = active
        queryUsed = q
        break
    }
    }

guard !titles.isEmpty else {
    return nil
    }

        guard let best = bestPlayerName(from: titles, minCount: 1) else { return nil }

        let cleaned = sanitizePlayerName(best)
        guard !cleaned.isEmpty else { return nil }

        let ocr = sanitizeNameForComparison(currentPlayerName)
        let ebay = sanitizeNameForComparison(cleaned)

        let confidence: Double
        if ocr.isEmpty {
        confidence = 1.0
        } else {
        confidence = normalizedSimilarity(ocr, ebay)
        
        // CRITICAL: If OCR detected a valid-looking name (2 words, capitalized),
        // and eBay suggests something COMPLETELY different (similarity < 0.3),
        // REJECT the eBay suggestion - it's likely a false positive
        let ocrWords = currentPlayerName.split(separator: " ").map(String.init)
        let looksLikeValidOCR = ocrWords.count >= 2 
                             && ocrWords.allSatisfy { $0.first?.isUppercase == true && $0.count >= 2 }
        
        if looksLikeValidOCR && confidence < 0.3 {
            return nil
        }
    }

        let display = normalizePlayerNameDisplay(cleaned)

        // titre qui match le mieux (optionnel)
        let lowerDisplay = display.lowercased()
        let titleMatched = titles.first(where: { $0.lowercased().contains(lowerDisplay) })

        return NameSuggestion(
        name: display,
        confidence: confidence,
        titleMatched: titleMatched,
        titles: titles,
        triedQueries: queries,
        queryUsed: queryUsed
        )
    }

/// Normalise un nom pour comparaison (minuscules, lettres/chiffres/espaces seulement, espaces compressÃ©s).
    private static func sanitizeNameForComparison(_ s: String) -> String {
        let lower = s.lowercased()
        let allowed = lower.map { ch -> Character in
        if ch.isLetter || ch.isNumber || ch == " " { return ch }
        return " "
    }
        let collapsed = String(allowed)
        .split(whereSeparator: { $0 == " " })
        .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    /// Cleans a player name extracted from eBay titles (remove noise like positions/brands).
    /// Returns an empty string if nothing usable.
    private static func sanitizePlayerName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if containsCyrillic(trimmed) { return "" }
        if !isAsciiOrLatinOnly(trimmed) { return "" }

        func alphaKey(_ s: String) -> String {
        let up = s.uppercased()
        let letters = up.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return String(String.UnicodeScalarView(letters))
    }

        let deny: Set<String> = [
        // Positions
        "C","LW","RW","LD","RD","G","F","D",
        // Common card/brand words that can be mistaken for names
        "UPPER","DECK","SERIES","YOUNG","GUNS","ROOKIE","RC","HOCKEY","NHL","NHLPA",
        "AUTHENTIC","FUTURE","WATCH","AUTO","AUTOGRAPH","PATCH","MEMORABILIA",
        "ENCORE","CUP","QUEST",
        "AUTHENTIC","GAME","USED","ROOKIES","SP",
        // Parallel colors (not valid as names)
        "BLUE","GOLD","SILVER","PURPLE","ORANGE","PINK","RAINBOW"
        ]
        
        // Colors that CAN be last names (Green, White, Red) - only bad as FIRST word
        let colorsOnlyBadAsFirst: Set<String> = ["GREEN","WHITE","RED"]

        let mapped = trimmed.map { ch -> Character in
        if ch.isLetter || ch == " " || ch == "'" { return ch }
        return " "
    }

        let parts = String(mapped)
        .replacingOccurrences(of: "â€™", with: "'")
        .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        .map { String($0) }
        .filter { !$0.isEmpty }

        var keep: [String] = []
        for p in parts {
        let k = alphaKey(p)
        if k.isEmpty { continue }
        if k.count == 1 { continue }
        if deny.contains(k) { continue }
        keep.append(p)
    }

        if keep.isEmpty { return "" }
        if keep.count >= 3 { keep = Array(keep.suffix(2)) }
        
        // 🎨 If first word is a color that can be a last name (Green/White/Red),
        // reject it as first name but keep it as last name
        // "Blue Frank" → rejected, "Colin White" → accepted
        if let first = keep.first {
            let firstKey = alphaKey(first)
            if colorsOnlyBadAsFirst.contains(firstKey) {
                // Remove the color from first position
                keep.removeFirst()
                if keep.isEmpty { return "" }
            }
        }

        let cleaned = keep
        .map { $0.lowercased().split(separator: " ").map { $0.capitalized }.joined(separator: " ") }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        let upper = cleaned.uppercased()
        let banned: [String] = [
        "TRACKING SYSTEMS",
        "FUTURE WATCH",
        "FUTUREWATCH",
        "YOUNG GUNS",
        "YOUNGGUNS",
        "U-PICK",
        "UPICK"
        ]
        if banned.contains(where: { upper.contains($0) }) { return "" }

        return cleaned
    }

    // MARK: - Minimum viable set-name inference (eBay titles + card number heuristic)

    /// Tries to infer a better `setName` (e.g., "Series 2 Young Guns") using:
    /// 1) Card number heuristics for Upper Deck flagship Young Guns (S1: 201-250, S2: 451-500)
    /// 2) Keyword voting from eBay Browse API titles ("Series 2", "Young Guns")
    ///
    /// Returns nil if it can't confidently improve the current value.
    static func setNameSuggestionMinimumViable(
        currentSetName: String,
        company: String,
        cardNumber: String,
        titles: [String]
    ) -> String? {

        let current = currentSetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let companyU = company.uppercased()

        func digitsOnly(_ s: String) -> Int? {
        let d = s.filter { $0.isNumber }
        return Int(d)
    }

        // Only try to fill/upgrade if missing or incomplete.
        let hasYoungGuns = current.uppercased().contains("YOUNG GUNS")
        let hasSeries = current.uppercased().contains("SERIES")
        let shouldTry = current.isEmpty || !hasYoungGuns || !hasSeries
        guard shouldTry else { return nil }

        let n = digitsOnly(cardNumber)

        // Heuristic: UD flagship Young Guns ranges.
        if companyU.contains("UPPER DECK"), let n {
        if (451...500).contains(n) { return "Series 2 Young Guns" }
        if (201...250).contains(n) { return "Series 1 Young Guns" }
    }

        // Title voting: look for strong keywords.
        let upperTitles = titles.prefix(20).map { $0.uppercased() }
        var seenYoungGuns = false
        var seenSeries1 = false
        var seenSeries2 = false

        for u in upperTitles { // cap for speed
        if u.contains("YOUNG GUNS") { seenYoungGuns = true }
        if u.contains("SERIES 2") || u.contains("SERIES II") || u.contains("SERIES TWO") || u.contains("S2 ") || u.hasSuffix(" S2") {
            seenSeries2 = true
    }
        if u.contains("SERIES 1") || u.contains("SERIES I") || u.contains("SERIES ONE") || u.contains("S1 ") || u.hasSuffix(" S1") {
            seenSeries1 = true
    }
    }

        if seenYoungGuns && seenSeries2 { return "Series 2 Young Guns" }
        if seenYoungGuns && seenSeries1 { return "Series 1 Young Guns" }

        // If we at least know it's Young Guns, prefer to set that over empty.
        if seenYoungGuns && current.isEmpty { return "Young Guns" }

        
        // âœ… Tracking Systems (Series 1 / Series 2)
        if upperTitles.contains(where: { $0.contains("TRACKING SYSTEMS") }) {
        let isSeries1 = upperTitles.contains(where: { $0.contains("SERIES 1") || $0.contains("SERIES1") })
        let isSeries2 = upperTitles.contains(where: { $0.contains("SERIES 2") || $0.contains("SERIES2") })
        if isSeries1 { return "Series 1 Tracking Systems" }
        if isSeries2 { return "Series 2 Tracking Systems" }
        return "Tracking Systems"
    }

return nil
    }



    static func suggestPlayerName(
    currentPlayerName: String,
    year: String?,
    company: String?,
    setName: String?,
    cardNumber: String?
) async -> String? {

    // We want to verify/correct *every* player when eBay is configured.
    // If the OCR name is empty or suspicious, we still try using the other keys (year/set/#).
    let hasUsefulKey =
        !(cardNumber?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ?? true) ||
        !(setName?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ?? true) ||
        !(year?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ?? true)

    guard hasUsefulKey else { return nil }

    func cleanNameForQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        func alphaKey(_ s: String) -> String {
        let up = s.uppercased()
        let letters = up.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return String(String.UnicodeScalarView(letters))
    }

        let deny: Set<String> = [
        "C","LW","RW","LD","RD","G","F","D",
        "BLUES","LUES","ILUES","BLOES",
        "UPPER","DECK","SERIES","YOUNG","GUNS","HOCKEY","NHL"
        ]

        let parts = trimmed
        .replacingOccurrences(of: "â€¢", with: " ")
        .replacingOccurrences(of: "Â·", with: " ")
        .replacingOccurrences(of: "Â®", with: " ")
        .replacingOccurrences(of: "\"", with: " ")
        .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        .map { String($0) }
        .filter { !$0.isEmpty }

        var keep: [String] = []
        for p in parts {
        let k = alphaKey(p)
        if k.isEmpty { continue }
        if k.count == 1 { continue }
        if deny.contains(k) { continue }
        keep.append(p)
    }

        if keep.isEmpty { return nil }
        // Use up to 3 tokens for queries (to support 3-word last names like "Del Gaizo").
// Prefer a known 3-token full name when available.
if keep.count == 3 {
    let three = keep.joined(separator: " ")
    if !KnownPlayerNames.isKnown(three) {
        keep = Array(keep.suffix(2))
    }
    } else if keep.count >= 4 {
    keep = Array(keep.suffix(3))
    }
return keep.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    let cleanedName = cleanNameForQuery(currentPlayerName)

    // Build a robust query: year + company + set + # + (optional) player name
    var qParts: [String] = []
    if let year, !year.isEmpty { qParts.append(year) }
    if let company, !company.isEmpty { qParts.append(company) }
    if let setName, !setName.isEmpty {
        let setQuery = setName
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "â€“", with: " ")
        .replacingOccurrences(of: "â€”", with: " ")
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !setQuery.isEmpty { qParts.append(setQuery) }
    }
    var cardNumberInt: Int? = nil

    if let cardNumber, !cardNumber.isEmpty {
        let cleaned = cardNumber.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let noHash = cleaned.hasPrefix("#") ? String(cleaned.dropFirst()) : cleaned
        // If it's purely digits, prefix with '#'. Otherwise keep as-is (e.g., "CQ-8").
        if noHash.range(of: "^\\d+$", options: String.CompareOptions.regularExpression) != nil {
        cardNumberInt = Int(noHash)
        qParts.append("#\(noHash)")
        } else {
        qParts.append(noHash)
    }
    }
    if let cleanedName, !cleanedName.isEmpty { qParts.append(cleanedName) }

    // If name is empty, still search with other keys (often enough for YG / SPA / etc.)
    let baseQuery = qParts.joined(separator: " ")
    if baseQuery.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty { return nil }

    // Try a few increasingly broad queries (eBay can be picky, and OCR sometimes adds noise)
    let setTokens = Set((setName ?? "").uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) })
    var candidates: [String] = []
    candidates.append(baseQuery)

    if let company, !company.isEmpty {
        let q = qParts.filter { $0.caseInsensitiveCompare(company) != .orderedSame }.joined(separator: " ")
        candidates.append(q)
    }
    if let year, !year.isEmpty {
        let q = qParts.filter { $0.caseInsensitiveCompare(year) != .orderedSame }.joined(separator: " ")
        candidates.append(q)
    }
    if let setName, !setName.isEmpty, !setTokens.isEmpty {
        let q = qParts.filter { !setTokens.contains($0.uppercased()) }.joined(separator: " ")
        candidates.append(q)
    }

    candidates = Array(NSOrderedSet(array: candidates))
        .compactMap { $0 as? String }

        // Extra fallbacks when player name is missing/weak but we have strong identifiers (#, year, set).
        // These broader queries help eBay return a result even if OCR polluted the query with noise.
        if let n = cardNumberInt {
        let yearStr = year?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let comp = company?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let set = setName?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        let hasYoungGuns = (set?.uppercased().contains("YOUNG") == true && set?.uppercased().contains("GUN") == true)

        var extra: [String] = []
        // Most reliable: year + card # + Young Guns (optionally company)
        if hasYoungGuns {
            if let y = yearStr, !y.isEmpty { extra.append("\(y) #\(n) Young Guns") }
            if let y = yearStr, let c = comp, !y.isEmpty, !c.isEmpty { extra.append("\(y) \(c) #\(n) Young Guns") }
            if let c = comp, !c.isEmpty { extra.append("\(c) #\(n) Young Guns") }
    }

        // Fallback: remove set name entirely (often noisy) and rely on year/company/#.
        if let y = yearStr, !y.isEmpty { extra.append("\(y) #\(n)") }
        if let y = yearStr, let c = comp, !y.isEmpty, !c.isEmpty { extra.append("\(y) \(c) #\(n)") }
        if let c = comp, !c.isEmpty { extra.append("\(c) #\(n)") }

        // If set exists but isn't Young Guns, try a lighter version.
        if let y = yearStr, let s = set, !y.isEmpty, !s.isEmpty { extra.append("\(y) #\(n) \(s)") }

        candidates.append(contentsOf: extra)
        candidates = Array(Set(candidates))
    }
        candidates = candidates.map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
        candidates = candidates.filter { !$0.isEmpty }

    do {
        var titles: [String] = []

        // 1) Try SOLD comps first (more reliable pricing/metadata), but new releases may have zero sold.
        for q in candidates {
        titles = try await searchItemTitles(query: q, limit: 12, soldOnly: true)
        if !titles.isEmpty { break }
    }

        // 2) Fallback to ACTIVE listings if sold comps are empty (this fixes the "new product, no sold yet" gap).
        if titles.isEmpty {
        for q in candidates {
            titles = try await searchItemTitles(query: q, limit: 12, soldOnly: false)
            if !titles.isEmpty { break }
    }
    }

        if titles.isEmpty { return nil }

        let isSurnameOnly = (cleanedName != nil) ? (cleanedName!.split(separator: " ", omittingEmptySubsequences: true).count == 1) : false
        let minCount = (cleanedName == nil) ? 1 : (isSurnameOnly ? 1 : 2)
        guard let best = bestPlayerName(from: titles, minCount: minCount) else { return nil }

        if let cleanedName, !cleanedName.isEmpty {
        // If OCR already matches (case-insensitive), keep it
        if best.caseInsensitiveCompare(cleanedName) == .orderedSame {
            return cleanedName
    }

        // Soft gate: if OCR name looks "surname-only" or contains junk tokens,
        // we accept eBay suggestion more readily.
        let surnameOnly = cleanedName.split(separator: " ").count == 1
        if surnameOnly { return best }

        // Otherwise, require reasonable similarity
        let sim = normalizedSimilarity(cleanedName, best)
        if sim >= 0.70 { return best }

        return nil
        } else {
        // OCR empty: accept the best name eBay extracted (minCount already relaxed)
        return best
    }
    } catch {
        return nil
    }
    }

// MARK: eBay calls (Finding API â€” no OAuth)

    /// Map Info.plist marketplace id (ex: EBAY_CA) to Finding API GLOBAL-ID (ex: EBAY-ENCA)
    private static var findingGlobalId: String {
        let marketplace = (InfoPlist.string("EBAY_MARKETPLACE_ID") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch marketplace.uppercased() {
        case "EBAY_CA": return "EBAY-ENCA"
        case "EBAY_US": return "EBAY-US"
        case "EBAY_GB": return "EBAY-GB"
        case "EBAY_AU": return "EBAY-AU"
        default:
        // Safe default: Canada (your app is configured for EBAY_CA in Info.plist)
        return "EBAY-ENCA"
    }
    }

    private struct FindingApiResponseEnvelope: Decodable {
        let findItemsByKeywordsResponse: [FindingApiResponse]?
        let findCompletedItemsResponse: [FindingApiResponse]?
    }

    private struct FindingApiResponse: Decodable {
        let ack: [String]?
        let searchResult: [FindingSearchResult]?
        let errorMessage: [FindingErrorMessage]?
    }

    private struct FindingSearchResult: Decodable {
        let item: [FindingItem]?
    }

    private struct FindingItem: Decodable {
        let title: [String]?
    }

    private struct FindingErrorMessage: Decodable {
        let error: [FindingError]?
    }

    private struct FindingError: Decodable {
        let message: [String]?
        let errorId: [String]?
        let severity: [String]?
    }


struct FindingCallResult {
        let titles: [String]
        let ack: String
        let errorMessage: String?
        let usedUrl: String
        let httpStatus: Int?
        let bodyPreview: String?

        // Primary initializer (keeps call sites readable)
        init(
        titles: [String],
        ack: String,
        errorMessage: String? = nil,
        usedUrl: String,
        httpStatus: Int? = nil,
        bodyPreview: String? = nil
        ) {
        self.titles = titles
        self.ack = ack
        self.errorMessage = errorMessage
        self.usedUrl = usedUrl
        self.httpStatus = httpStatus
        self.bodyPreview = bodyPreview
    }

        // Backward-compatible initializer (older debug payload shape).
        // Some earlier app revisions expected additional fields like rawTitlesCount/cleanedTitlesCount/queryUsed/etc.
        // We ignore them but keep this initializer so older call sites compile.
        init(
        ack: String,
        titles: [String],
        rawTitlesCount: Int,
        cleanedTitlesCount: Int,
        queryUsed: String,
        triedQueries: [String],
        inferred: Any?
        ) {
        self.titles = titles
        self.ack = ack
        self.errorMessage = nil
        self.usedUrl = queryUsed
        self.httpStatus = nil
        self.bodyPreview = nil
    }
    }

    /// Low-level Finding API call. Returns titles + ack/error + the final URL (for debug UI).
    private static func findingSearchTitles(query: String, limit: Int, soldOnly: Bool) async throws -> FindingCallResult {

// âœ… Preferred path: use Cardia backend proxy (Cloud Run / Firebase) when configured.
if let base = proxyBaseURL {
    let market = (findingGlobalId == "EBAY-ENCA") ? "CA" : "US"
    let (titles, queryUsed, _, httpStatus, bodyPreview, usedUrl, err) = try await proxySuggest(
        base: base,
        queries: [query],
        market: market,
        limit: max(1, min(limit, 50)),
        soldOnly: soldOnly
    )
    let ack = err == nil ? "PROXY_OK" : "PROXY_ERROR"
    var msg: String? = nil
    if let err = err { msg = err }
    if !(200...299).contains(httpStatus) {
        msg = (msg == nil) ? "HTTP \(httpStatus)" : "HTTP \(httpStatus) â€¢ \(msg!)"
    }
    // Include a short preview when failing (helps debug from the UI)
    if let prev = bodyPreview, !prev.isEmpty, !(200...299).contains(httpStatus) {
        msg = (msg ?? "") + "\n" + prev
    }
    return FindingCallResult(
        titles: titles,
        ack: ack,
        errorMessage: msg,
        usedUrl: queryUsed ?? usedUrl,
        httpStatus: httpStatus,
        bodyPreview: bodyPreview
    )
    }

        guard isConfigured else {
        return FindingCallResult(titles: [], ack: "NOT_CONFIGURED", errorMessage: "eBay non configurÃ©: ajoute EBAY_CLIENT_ID (ou EBAY_APP_ID) dans Info.plist.", usedUrl: "")
    }

        let opName = soldOnly ? "findCompletedItems" : "findItemsByKeywords"

        var urlc = URLComponents(string: "https://svcs.ebay.com/services/search/FindingService/v1")!
        var q: [URLQueryItem] = [
        URLQueryItem(name: "OPERATION-NAME", value: opName),
        URLQueryItem(name: "SERVICE-VERSION", value: "1.13.0"),
        URLQueryItem(name: "SECURITY-APPNAME", value: appID),
        URLQueryItem(name: "GLOBAL-ID", value: findingGlobalId),
        URLQueryItem(name: "RESPONSE-DATA-FORMAT", value: "JSON"),
        URLQueryItem(name: "REST-PAYLOAD", value: "true"),
        URLQueryItem(name: "keywords", value: query),
        URLQueryItem(name: "paginationInput.entriesPerPage", value: String(max(1, min(limit, 50))))
        ]

        if soldOnly {
        q.append(URLQueryItem(name: "itemFilter(0).name", value: "SoldItemsOnly"))
        q.append(URLQueryItem(name: "itemFilter(0).value", value: "true"))
    }

        urlc.queryItems = q
        guard let url = urlc.url else { throw URLError(.badURL) }

        let (data, resp) = try await URLSession.shared.data(from: url)
        let http = resp as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1

        // Decode as per Finding API JSON shape.
        let decoded = try JSONDecoder().decode(FindingApiResponseEnvelope.self, from: data)
        let root = soldOnly ? decoded.findCompletedItemsResponse?.first : decoded.findItemsByKeywordsResponse?.first

        let ack = root?.ack?.first ?? "UNKNOWN"
        var titles: [String] = []
        if let items = root?.searchResult?.first?.item {
        titles = items.compactMap { $0.title?.first?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

        var errMsg: String? = nil
        if let err = root?.errorMessage?.first?.error?.first {
        let msg = err.message?.first ?? "Erreur eBay inconnue"
        let id = err.errorId?.first ?? ""
        let sev = err.severity?.first ?? ""
        errMsg = "[\(sev)] \(id) \(msg)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

        // If HTTP is not 2xx, surface that too
        if !(200...299).contains(statusCode) {
        let httpMsg = "HTTP \(statusCode)"
        errMsg = (errMsg == nil) ? httpMsg : "\(httpMsg) â€¢ \(errMsg!)"
    }

        

        // Short preview of the raw body (useful when eBay returns an error or unexpected payload)
        let bodyPreview: String? = {
        if let s = String(data: data, encoding: .utf8) {
            return String(s.prefix(900))
    }
        return nil
        }()
return FindingCallResult(
        titles: titles,
        ack: ack,
        errorMessage: errMsg,
        usedUrl: url.absoluteString,
        httpStatus: statusCode,
        bodyPreview: bodyPreview
        )
    }

    /// Convenience wrapper used by the rest of the file (keeps older call sites stable).
    static func searchItemTitles(query: String, limit: Int = 25, soldOnly: Bool = false) async throws -> [String] {
        // âœ… Prefer backend proxy (Cloud Run) when configured to avoid eBay client-side rate limits.
        if let base = proxyBaseURL {
        // Keep it simple: send the query plus one slightly broadened variant.
        let q = cleanEbayQuery(query)
        let queries = [q, "hockey card \(q)"].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let market = (findingGlobalId == "EBAY-ENCA") ? "CA" : "US"
        let (titles, _, _, _, _, _, err) = try await proxySuggest(
            base: base,
            queries: queries,
            market: market,
            limit: limit,
            soldOnly: soldOnly
        )
        if let err, !err.isEmpty {
            // Proxy responded with an explicit error (still return empty titles but surface error to caller)
            throw NSError(domain: "EbaySoftCorrector.Proxy", code: -1, userInfo: [NSLocalizedDescriptionKey: err])
    }
        return filterNoiseTitles(titles)
    }

        // Fallback to legacy FindingService direct call (dev-only).
        let r = try await findingSearchTitles(query: query, limit: limit, soldOnly: soldOnly)
        return filterNoiseTitles(r.titles)
    }



    /// Debug variant that returns transport details to help diagnose "0 results".
    /// Returns (titles, source, usedUrl, httpStatus, bodyPreview, errorMessage).
    static func searchItemTitlesDebug(query: String, limit: Int = 25, soldOnly: Bool = false) async -> ([String], String, String, Int?, String?, String?) {
        // Prefer backend proxy when configured.
        if let base = proxyBaseURL {
        do {
            let q = cleanEbayQuery(query)
            let queries = [q, "hockey card \(q)"].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let market = (findingGlobalId == "EBAY-ENCA") ? "CA" : "US"
            let (titles, _, _, http, body, usedUrl, err) = try await proxySuggest(
                base: base,
                queries: queries,
                market: market,
                limit: limit,
                soldOnly: soldOnly
            )
            return (filterNoiseTitles(titles), "PROXY", usedUrl, http, body, err)
        } catch {
            return ([], "PROXY", base.appendingPathComponent("ebay/suggest").absoluteString, nil, nil, error.localizedDescription)
    }
    }

        // Legacy direct call (FindingService)
        do {
        let r = try await findingSearchTitles(query: query, limit: limit, soldOnly: soldOnly)
        return (filterNoiseTitles(r.titles), "DIRECT", r.usedUrl, r.httpStatus, r.bodyPreview, r.errorMessage)
        } catch {
        return ([], "DIRECT", "", nil, nil, error.localizedDescription)
    }
    }

    // MARK: - Cardia backend proxy (Cloud Run)

    private struct ProxySuggestRequest: Encodable {
        let queries: [String]
        let market: String?
        let limit: Int?
        let soldOnly: Bool?
    }

    private struct ProxySuggestResponse: Decodable {
        let titles: [String]?
        let rawTitlesCount: Int?
        let cleanedTitlesCount: Int?
        let queryUsed: String?
        let triedQueries: [String]?
        let inferred: String?
        let marketplaceId: String?
        let ok: Bool?
        let error: String?
        let message: String?
    }

    /// Calls the backend proxy `POST /ebay/suggest`.
    /// Returns (titles, queryUsed, triedQueries, httpStatus, bodyPreview, usedUrl, errorMessage).
    private static func proxySuggest(
        base: URL,
        queries: [String],
        market: String,
        limit: Int,
        soldOnly: Bool
    ) async throws -> ([String], String?, [String], Int, String?, String, String?) {

        let url = base.appendingPathComponent("ebay/suggest")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ProxySuggestRequest(
        queries: queries,
        market: market,
        limit: limit,
        soldOnly: soldOnly
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = (resp as? HTTPURLResponse)
        let status = http?.statusCode ?? -1

        let rawBodyPreview: String = {
        let s = String(data: data, encoding: .utf8) ?? ""
        return String(s.prefix(900))
        }()


        // Best effort decode (robust to backend type changes)
        let decoded: ProxySuggestResponse? = (try? JSONDecoder().decode(ProxySuggestResponse.self, from: data))

        var titles: [String] = decoded?.titles ?? []
        var queryUsed: String? = decoded?.queryUsed
        var tried: [String] = decoded?.triedQueries ?? queries
        var err: String? = nil
        var preview: String? = nil

        // If decoding failed, attempt a loose parse so we can at least extract `titles`.
        if decoded == nil {
        if let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] {
            if let t = obj["titles"] as? [String] { titles = t }
            if let qu = obj["queryUsed"] as? String { queryUsed = qu }
            if let tq = obj["triedQueries"] as? [String] { tried = tq }
            if let e = obj["error"] as? String, !e.isEmpty { err = e }
            if err == nil, let m = obj["message"] as? String, !m.isEmpty { err = m }
    }
        } else {
        if let e = decoded?.error, !e.isEmpty { err = e }
        if err == nil, let m = decoded?.message, !m.isEmpty { err = m }
    }

        if let e = err, !e.isEmpty {
        preview = rawBodyPreview
        } else if !(200...299).contains(status) {
        err = "HTTP \(status)"
        preview = rawBodyPreview
        } else if decoded == nil && titles.isEmpty {
        // 200 OK but we couldn't decode AND we couldn't extract titles; show preview.
        err = "PROXY_DECODE_FAILED"
        preview = rawBodyPreview
        } else if titles.isEmpty {
        // Still show a short preview when we got 0 titles; helps diagnose query/market mismatch.
        preview = rawBodyPreview
    }

        return (titles, queryUsed, tried, status, preview, url.absoluteString, err)
    }
// MARK: eBay (Finding API) helpers

    /// Searches eBay completed/sold listings and returns a list of item titles.
    /// Uses the legacy FindingService `findCompletedItems` endpoint (AppID only; no OAuth).




    /// Normalized similarity score [0..1] based on token Jaccard + bigram overlap (robust to OCR noise).
    private static func normalizedSimilarity(_ a: String, _ b: String) -> Double {
        let ta = tokenizeForSimilarity(a)
        let tb = tokenizeForSimilarity(b)
        if ta.isEmpty || tb.isEmpty { return 0 }

        let setA = Set(ta)
        let setB = Set(tb)
        let inter = Double(setA.intersection(setB).count)
        let union = Double(setA.union(setB).count)
        let jaccard = union > 0 ? inter / union : 0

        let ba = Set(bigramsForSimilarity(a))
        let bb = Set(bigramsForSimilarity(b))
        let bInter = Double(ba.intersection(bb).count)
        let bUnion = Double(ba.union(bb).count)
        let bigram = bUnion > 0 ? bInter / bUnion : 0

        // Weighted blend; tokens matter more than character noise.
        return (0.7 * jaccard) + (0.3 * bigram)
    }

    private static func tokenizeForSimilarity(_ s: String) -> [String] {
        let cleaned = s
        .lowercased()
        .replacingOccurrences(of: "â€™", with: "'")
        .replacingOccurrences(of: "Â®", with: "")
        .replacingOccurrences(of: "â„¢", with: "")
        .replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: String.CompareOptions.regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: String.CompareOptions.regularExpression)
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return cleaned.split(separator: " ").map { String($0) }.filter { $0.count >= 2 }
    }

    private static func bigramsForSimilarity(_ s: String) -> [String] {
        let cleaned = s
        .lowercased()
        .replacingOccurrences(of: "[^a-z0-9]", with: "", options: String.CompareOptions.regularExpression)
        guard cleaned.count >= 2 else { return [] }
        let arr = Array(cleaned)
        var grams: [String] = []
        grams.reserveCapacity(arr.count - 1)
        for i in 0..<(arr.count - 1) {
        grams.append(String(arr[i]) + String(arr[i+1]))
    }
        return grams
    }

private static func bestPlayerName(from titles: [String], minCount: Int = 2) -> String? {
    // ULTRA-SIMPLE FIX: Take ONLY the first name from the first title
    // This is the most relevant result and prevents contamination from multi-player lots
    guard !titles.isEmpty else { return nil }
    
    let names = extractCandidateNames(from: titles[0])
    
    // If we have validated names, prefer those
    let validatedNames = names.filter { name in
        KnownPlayers.canonicalize(name) != nil
    }
    
    // Return first validated name, or first name if no validated names
    if let firstValidated = validatedNames.first {
        return firstValidated
    }
    
    return names.first
    }

    private static func extractCandidateNames(from title: String) -> [String] {
        // Normalize separators
        let cleaned = title
        .replacingOccurrences(of: "#", with: " ")
        .replacingOccurrences(of: "/", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "â€¢", with: " ")
        .replacingOccurrences(of: "(", with: " ")
        .replacingOccurrences(of: ")", with: " ")
        .replacingOccurrences(of: "[", with: " ")
        .replacingOccurrences(of: "]", with: " ")

        // Candidate pattern: two words of letters (allow apostrophe)
        let pattern = #"(?i)\b([A-Z][A-Z']{1,}|[A-Z][a-z']{1,})\s+([A-Z][A-Z']{1,}|[A-Z][a-z']{1,})\b"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = cleaned as NSString
        let matches = regex.matches(in: cleaned, options: [], range: NSRange(location: 0, length: ns.length))

        var out: [String] = []
        for m in matches {
        if m.numberOfRanges < 3 { continue }
        let w1 = ns.substring(with: m.range(at: 1)).uppercased()
        let w2 = ns.substring(with: m.range(at: 2)).uppercased()

        // Deny common non-name words
        let deny: Set<String> = [
            "UPPER","DECK","SERIES","HOCKEY","ROOKIE","RC","AUTO","AUTOGRAPH","PATCH",
            "CUP","QUEST","INSERT","PARALLEL","GOLD","SILVER","BLUE",
            "PURPLE","ORANGE","PINK","RAINBOW","CLEAR","ICE",
            "TORONTO","MAPLE","LEAFS","NHL","NHLPA","SP",
            "GAME","USED","AUTHENTIC","ROOKIES","BASE","YOUNG","GUNS","CANVAS",
            "EXCLUSIVES","CHICAGO","BLACKHAWKS","DETROIT","WINGS","BOSTON","BRUINS"
        ]
        
        // Colors that CAN be last names - only block as FIRST word
        let colorsOnlyBadAsFirst: Set<String> = ["GREEN","WHITE","RED"]
        
        if deny.contains(w1) || deny.contains(w2) { continue }
        
        // Block colors only if they're the first word (first name)
        // "Blue Frank" → blocked, "Colin White" → allowed
        if colorsOnlyBadAsFirst.contains(w1) { continue }
        
        // CRITICAL: Block set names that look like player names
        let fullName = "\(w1) \(w2)"
        let denyFullNames: Set<String> = [
            "GAME USED", "AUTHENTIC ROOKIES", "YOUNG GUNS", "UPPER DECK",
            "RED WINGS", "MAPLE LEAFS", "BLUE JACKETS", "GOLDEN KNIGHTS",
            "CUP QUEST", "FUTURE WATCH", "SIZZLE REEL", "DAZZLERS ALL",
            "POPULATION COUNT",
            "ZENON KONOPKA"  // Retired ~2015
        ]
        if denyFullNames.contains(fullName) { continue }
        
        if w1.count <= 2 || w2.count <= 2 { continue }
        if !w1.allSatisfy({ $0.isLetter || $0 == "'" }) { continue }
        if !w2.allSatisfy({ $0.isLetter || $0 == "'" }) { continue }

        out.append(fullName)
    }

        return out
    }

    // MARK: Similarity helpers

    private static func similarity(_ a: String, _ b: String) -> Double {
        // Normalized Levenshtein similarity in [0,1]
        if a == b { return 1.0 }
        let dist = levenshtein(a, b)
        let maxLen = max(a.count, b.count)
        if maxLen == 0 { return 1.0 }
        return 1.0 - (Double(dist) / Double(maxLen))
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        if n == 0 { return m }
        if m == 0 { return n }

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }

        for i in 1...n {
        for j in 1...m {
            let cost = (aChars[i - 1] == bChars[j - 1]) ? 0 : 1
            dp[i][j] = min(
                dp[i - 1][j] + 1,
                dp[i][j - 1] + 1,
                dp[i - 1][j - 1] + cost
            )
    }
    }
        return dp[n][m]
    }


    // MARK: - General connectivity test (Finding API)
    // Purpose: validate that the Finding API is reachable and that the AppID is accepted.
    // Uses a very broad keyword query that should return many results if the API works.
    static func generalConnectivityTest(limit: Int = 5) async -> FindingCallResult {
        do {
        return try await findingSearchTitles(query: "hockey card", limit: limit, soldOnly: false)
        } catch {
        // On renvoie un rÃ©sultat "Failure" plutÃ´t que de faire crasher l'appelant.
        return FindingCallResult(
            titles: [],
            ack: "Failure",
            errorMessage: error.localizedDescription,
            usedUrl: ""
        )
    }
    }

private enum InfoPlist {
    static func string(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
    }

// MARK: - eBay Browse API (OAuth app token) â€” Debug helper (US/CA)

private enum EbayBrowseAPIDebugger {

    struct GeneralTestResult {
        let us: MarketplaceResult
        let ca: MarketplaceResult
    }

    struct MarketplaceResult {
        let marketplaceId: String
        let httpStatus: Int
        let bodyPreview: String
        let sampleTitles: [String]

        var statusText: String {
        if (200...299).contains(httpStatus) {
            return "OK"
    }
        // Show status + short body snippet
        let snippet = bodyPreview.isEmpty ? "" : " â€” \(bodyPreview)"
        return "\(httpStatus)\(snippet)"
    }
    }

    // âœ… Uses OAuth *application* token (client credentials) + Browse API search.
    static func runGeneralTest(query: String, limit: Int = 5) async throws -> GeneralTestResult {
        let token = try await fetchOAuthAppToken()

        async let us = browseSearch(marketplaceId: "EBAY_US", token: token, query: query, limit: limit)
        async let ca = browseSearch(marketplaceId: "EBAY_CA", token: token, query: query, limit: limit)

        return try await GeneralTestResult(us: us, ca: ca)
    }

    // MARK: OAuth app token

    private struct OAuthTokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let token_type: String?
    }

    private static func fetchOAuthAppToken() async throws -> String {
        guard let clientId = InfoPlist.string("EBAY_CLIENT_ID"),
          let clientSecret = InfoPlist.string("EBAY_CLIENT_SECRET"),
          !clientId.isEmpty,
          !clientSecret.isEmpty else {
        throw NSError(domain: "EbayBrowseAPIDebugger", code: 1, userInfo: [NSLocalizedDescriptionKey: "EBAY_CLIENT_ID / EBAY_CLIENT_SECRET manquants dans Info.plist"])
    }

        let credentials = "\(clientId):\(clientSecret)"
        guard let credsData = credentials.data(using: .utf8) else {
        throw NSError(domain: "EbayBrowseAPIDebugger", code: 2, userInfo: [NSLocalizedDescriptionKey: "Impossible d'encoder les credentials"])
    }

        var request = URLRequest(url: URL(string: "https://api.ebay.com/identity/v1/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(credsData.base64EncodedString())", forHTTPHeaderField: "Authorization")

        // Scope minimal pour Browse API (app token)
        let scope = "https://api.ebay.com/oauth/api_scope"
        let bodyString = "grant_type=client_credentials&scope=\(scope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scope)"
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        if !(200...299).contains(status) {
        let preview = previewBody(data)
        throw NSError(domain: "EbayBrowseAPIDebugger", code: status, userInfo: [NSLocalizedDescriptionKey: "OAuth token error \(status): \(preview)"])
    }

        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        return decoded.access_token
    }

    // MARK: Browse API search

    private struct BrowseSearchResponse: Decodable {
        struct ItemSummary: Decodable {
        let title: String?
    }
        let total: Int?
        let itemSummaries: [ItemSummary]?
    }

    private static func browseSearch(marketplaceId: String, token: String, query: String, limit: Int) async throws -> MarketplaceResult {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://api.ebay.com/buy/browse/v1/item_summary/search?q=\(q)&limit=\(max(1, min(limit, 20)))")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(marketplaceId, forHTTPHeaderField: "X-EBAY-C-MARKETPLACE-ID")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyPrev = previewBody(data)

        var titles: [String] = []
        if (200...299).contains(status) {
        if let decoded = try? JSONDecoder().decode(BrowseSearchResponse.self, from: data) {
            titles = (decoded.itemSummaries ?? []).compactMap { $0.title }.filter { !$0.isEmpty }
    }
    }

        return MarketplaceResult(
        marketplaceId: marketplaceId,
        httpStatus: status,
        bodyPreview: (200...299).contains(status) ? "" : bodyPrev,
        sampleTitles: titles
        )
    }

    private static func previewBody(_ data: Data) -> String {
        let s = String(data: data, encoding: .utf8) ?? ""
        let cleaned = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= 200 { return cleaned }
        let idx = cleaned.index(cleaned.startIndex, offsetBy: 200)
        return String(cleaned[..<idx]) + "â€¦"
    }
    }





    }
// MARK: UIKit Picker

private struct CVUIKitImagePicker: UIViewControllerRepresentable {

    let sourceType: UIImagePickerController.SourceType
    let onPicked: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onPicked: (UIImage?) -> Void
        init(onPicked: @escaping (UIImage?) -> Void) { self.onPicked = onPicked }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        onPicked(nil)
    }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        let img = (info[.originalImage] as? UIImage)
        onPicked(img)
    }
    }
    }


// MARK: OCR


private enum OCR {

    /// OCR mode. We use both for robustness (some fonts work better in `.fast`).
    private enum Mode {
        case accurate
        case fast

        var recognitionLevel: VNRequestTextRecognitionLevel {
        switch self {
        case .accurate: return .accurate
        case .fast: return .fast
    }
    }
    }

    private static func runCollect(on image: UIImage, note: String, mode: Mode = .accurate) async -> [String] {
        // Always work on oriented + (optionally) boosted image.
        guard let cgImage = image.cgImage else { return [] }
        let boosted = boostContrast(cgImage: cgImage) ?? cgImage

        return await withCheckedContinuation { continuation in
        let request = VNRecognizeTextRequest { req, err in
            if let err {
                print("âš ï¸ VNRecognizeTextRequest error (\(note)):", err.localizedDescription)
                continuation.resume(returning: [])
                return
            }

            let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }

            let cleaned = lines
                .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                // Reject obvious garbage scripts (Cyrillic etc.)
                .filter { !containsCyrillic($0) }

            continuation.resume(returning: cleaned)
    }

        request.recognitionLevel = mode.recognitionLevel
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.003
        request.recognitionLanguages = ["en-US", "fr-FR"]

        if #available(iOS 16.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
    }

        let handler = VNImageRequestHandler(cgImage: boosted, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do { try handler.perform([request]) }
            catch { continuation.resume(returning: []) }
    }
    }
    }

    /// Multi-pass OCR tuned for standard hockey cards:
    /// - Detect + perspective-correct the card rectangle
    /// - OCR on multiple bands (name band + bottom set/number bands) + full
    /// - Use both `.accurate` and `.fast` on key bands, then merge/dedupe
    static func runMultiPass(on image: UIImage, note: String) async -> [String] {
        // 1) Rectify perspective if possible (huge quality boost).
        let base = await rectifyCardIfPossible(image)

        // 2) Crop bands (ratios tuned for standard portrait hockey cards).
        let nameBand     = crop(image: base, x0: 0.00, x1: 1.00, y0: 0.06, y1: 0.34)
        let topLeftBand  = crop(image: base, x0: 0.00, x1: 0.28, y0: 0.00, y1: 0.18) // back card # is often here
        let bottomBand   = crop(image: base, x0: 0.00, x1: 1.00, y0: 0.70, y1: 1.00)
        let bottomLeft   = crop(image: base, x0: 0.00, x1: 0.56, y0: 0.78, y1: 1.00)
        let bottomRight  = crop(image: base, x0: 0.44, x1: 1.00, y0: 0.78, y1: 1.00)
        
        // NEW: Side bands for vertical text (like "SIZZLE REEL" on card edges)
        let leftSide     = crop(image: base, x0: 0.00, x1: 0.20, y0: 0.00, y1: 1.00)
        let rightSide    = crop(image: base, x0: 0.80, x1: 1.00, y0: 0.00, y1: 1.00)

        // 3) Run OCR: accurate on everything, plus fast on key bands.
        async let fullAcc   = runCollect(on: base, note: "\(note)_full_acc", mode: .accurate)

        async let nameAcc   = runCollect(on: nameBand ?? base, note: "\(note)_name_acc", mode: .accurate)
        async let nameFast  = runCollect(on: nameBand ?? base, note: "\(note)_name_fast", mode: .fast)

        async let botAcc    = runCollect(on: bottomBand ?? base, note: "\(note)_bottom_acc", mode: .accurate)

        // Extra pass: top-left corner (often contains the back card number, ex: "227")
        async let tlAcc     = runCollect(on: topLeftBand ?? base, note: "\(note)_tl_acc", mode: .accurate)
        async let tlFast    = runCollect(on: topLeftBand ?? base, note: "\(note)_tl_fast", mode: .fast)

        async let blAcc     = runCollect(on: bottomLeft ?? base, note: "\(note)_bl_acc", mode: .accurate)
        async let brAcc     = runCollect(on: bottomRight ?? base, note: "\(note)_br_acc", mode: .accurate)

        async let blFast    = runCollect(on: bottomLeft ?? base, note: "\(note)_bl_fast", mode: .fast)
        async let brFast    = runCollect(on: bottomRight ?? base, note: "\(note)_br_fast", mode: .fast)
        
        // NEW: OCR on side bands (for vertical text)
        async let leftAcc   = runCollect(on: leftSide ?? base, note: "\(note)_left_acc", mode: .accurate)
        async let rightAcc  = runCollect(on: rightSide ?? base, note: "\(note)_right_acc", mode: .accurate)
        
        // NEW: Try rotated image to read vertical text as horizontal (works better for OCR)
        let rotated = rotateClockwise90(base)
        async let rotAcc    = runCollect(on: rotated ?? base, note: "\(note)_rot90_acc", mode: .accurate)

        let (fa, na, nf, ba, tla, tlf, bla, bra, blf, brf, la, ra, rot) = await (fullAcc, nameAcc, nameFast, botAcc, tlAcc, tlFast, blAcc, brAcc, blFast, brFast, leftAcc, rightAcc, rotAcc)

        // 4) Merge with a simple vote: keep lines that appear in both fast+accurate first.
        func normalizeKey(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

        let nameVotes = Swift.Set(na.map(normalizeKey)).intersection(Swift.Set(nf.map(normalizeKey)))
        let tlVotes = Swift.Set(tla.map(normalizeKey)).intersection(Swift.Set(tlf.map(normalizeKey)))
        let blVotes = Swift.Set(bla.map(normalizeKey)).intersection(Swift.Set(blf.map(normalizeKey)))
        let brVotes = Swift.Set(bra.map(normalizeKey)).intersection(Swift.Set(brf.map(normalizeKey)))
        var ordered: [String] = []
        // High-confidence first (appear in both modes)
        ordered.append(contentsOf: na.filter { nameVotes.contains(normalizeKey($0)) })
        ordered.append(contentsOf: tla.filter { tlVotes.contains(normalizeKey($0)) })
        ordered.append(contentsOf: bla.filter { blVotes.contains(normalizeKey($0)) })
        ordered.append(contentsOf: bra.filter { brVotes.contains(normalizeKey($0)) })

        // Then the rest (still useful)
        ordered.append(contentsOf: na)
        ordered.append(contentsOf: nf)
        ordered.append(contentsOf: tla)
        ordered.append(contentsOf: tlf)
        ordered.append(contentsOf: ba)
        ordered.append(contentsOf: bla)
        ordered.append(contentsOf: bra)
        ordered.append(contentsOf: blf)
        ordered.append(contentsOf: brf)
        ordered.append(contentsOf: la)   // NEW: left side
        ordered.append(contentsOf: ra)   // NEW: right side
        ordered.append(contentsOf: rot)  // NEW: rotated 90Â° (vertical text)
        ordered.append(contentsOf: fa)

        // 5) Final dedupe + trimming + light garbage filtering.
        var seen = Swift.Set<String>()
        var merged: [String] = []
        for s in ordered {
        let key = normalizeKey(s)
        guard !key.isEmpty else { continue }
        // Avoid extremely long lines (usually OCR noise/paragraphs).
        if key.count > 80 { continue }
        if !seen.contains(key) {
            seen.insert(key)
            merged.append(key)
    }
    }
        return merged
    }

    // MARK: - Card rectification (Perspective correction)

    /// Attempts to detect the card rectangle and perspective-correct it.
    /// Falls back to the original image if detection fails.
    static func rectifyCardIfPossible(_ image: UIImage) async -> UIImage {
        guard let cg = image.cgImage else { return image }

        guard let rect = await detectLargestRectangle(in: cg) else { return image }
        guard let corrected = perspectiveCorrect(cgImage: cg, rect: rect) else { return image }
        return corrected
    }

    static func detectLargestRectangle(in cgImage: CGImage) async -> VNRectangleObservation? {
        await withCheckedContinuation { continuation in
        let request = VNDetectRectanglesRequest { req, err in
            if let err {
                print("âš ï¸ VNDetectRectanglesRequest error:", err.localizedDescription)
                continuation.resume(returning: nil)
                return
            }
            let rects = (req.results as? [VNRectangleObservation]) ?? []
            // Choose the largest (area) rectangle.
            let best = rects.max(by: { a, b in
                let aa = a.boundingBox.width * a.boundingBox.height
                let bb = b.boundingBox.width * b.boundingBox.height
                return aa < bb
            })
            continuation.resume(returning: best)
    }

        // Tuned for cards.
        request.minimumAspectRatio = 0.55
        request.maximumAspectRatio = 0.85
        request.minimumSize = 0.25
        request.maximumObservations = 3
        request.quadratureTolerance = 20.0

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do { try handler.perform([request]) }
            catch { continuation.resume(returning: nil) }
    }
    }
    }

    static func perspectiveCorrect(cgImage: CGImage, rect: VNRectangleObservation) -> UIImage? {
        let ci = CIImage(cgImage: cgImage)

        // Vision bounding points are normalized with origin at bottom-left.
        let w = ci.extent.width
        let h = ci.extent.height

        func denorm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * w, y: p.y * h)
    }

        let topLeft = denorm(rect.topLeft)
        let topRight = denorm(rect.topRight)
        let bottomLeft = denorm(rect.bottomLeft)
        let bottomRight = denorm(rect.bottomRight)

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")

        guard let out = filter.outputImage else { return nil }
        let ctx = CIContext(options: nil)
        guard let outCG = ctx.createCGImage(out, from: out.extent) else { return nil }
        
        var result = UIImage(cgImage: outCG, scale: currentScreenScale(), orientation: .up)
        
        // Cards are always portrait (taller than wide). If result is landscape, rotate it.
        if result.size.width > result.size.height {
            result = rotateToPortrait(result) ?? result
        }
        
        return result
    }
    
    /// Rotates a landscape image to portrait (90° counter-clockwise)
    private static func rotateToPortrait(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        let width = cgImage.height  // swapped
        let height = cgImage.width  // swapped
        
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: cgImage.bitmapInfo.rawValue
        ) else { return nil }
        
        // Rotate 90° counter-clockwise
        context.translateBy(x: 0, y: CGFloat(height))
        context.rotate(by: -.pi / 2)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        
        guard let rotated = context.makeImage() else { return nil }
        return UIImage(cgImage: rotated, scale: image.scale, orientation: .up)
    }

    // MARK: - Helpers
    private static func currentScreenScale() -> CGFloat {
        // iOS 26 deprecates `UIScreen.main`. Prefer a screen from the active window scene.
        let screens = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }
        return screens.first?.scale ?? 1.0
    }
    



    private static func crop(image: UIImage, x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat) -> UIImage? {
        guard x1 > x0, y1 > y0 else { return nil }
        guard let cg = image.cgImage else { return nil }

        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let rect = CGRect(
        x: w * x0,
        y: h * y0,
        width: w * (x1 - x0),
        height: h * (y1 - y0)
        ).integral

        guard let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }
    
    /// Rotates an image 90 degrees clockwise to help read vertical text
    private static func rotateClockwise90(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        let width = cgImage.width
        let height = cgImage.height
        
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = cgImage.bitmapInfo.rawValue
        
        guard let context = CGContext(
            data: nil,
            width: height,  // swapped
            height: width,  // swapped
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        
        context.translateBy(x: CGFloat(height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let rotated = context.makeImage() else { return nil }
        return UIImage(cgImage: rotated, scale: image.scale, orientation: .up)
    }

    private static func boostContrast(cgImage: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cgImage)

        let context = CIContext(options: nil)

        if let color = CIFilter(name: "CIColorControls") {
        color.setValue(ci, forKey: kCIInputImageKey)
        color.setValue(0.02, forKey: kCIInputBrightnessKey)
        color.setValue(1.35, forKey: kCIInputContrastKey)
        color.setValue(0.0, forKey: kCIInputSaturationKey)

        var out = color.outputImage ?? ci

        if let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(out, forKey: kCIInputImageKey)
            sharpen.setValue(0.42, forKey: kCIInputSharpnessKey)
            out = sharpen.outputImage ?? out
    }

        return context.createCGImage(out, from: out.extent)
    }

        return context.createCGImage(ci, from: ci.extent)
    }

    }
// MARK: Front parsing (lightweight)

private enum FrontOCRParser {

    struct FrontResult {
        var fullName: String?
        var playerLastName: String?
        var company: String?
        var setName: String?
        var cardNumber: String?
        var year: String?
    }

    static func parse(lines: [String]) -> FrontResult {
        var out = FrontResult()

        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let upper = cleaned.map { $0.uppercased() }

        // Year (season format like 2021-22)
        out.year = FrontOCRParser.findSeasonYear(in: cleaned)

        // Company
        if upper.contains(where: { $0.contains("UPPER") }) && upper.contains(where: { $0.contains("DECK") }) {
        out.company = "Upper Deck"
        } else if upper.contains(where: { $0.contains("TOPPS") }) {
        out.company = "Topps"
        } else if upper.contains(where: { $0.contains("PANINI") }) {
        out.company = "Panini"
    }

        // Card number (front sometimes has "#201" or "CQ-8")
        out.cardNumber = firstCardNumberLike(in: cleaned)

        // Player candidates: try full name first (front often has it)
        if let fn = bestFullName(from: cleaned) {
        out.fullName = titleCasedName(fn)
        out.playerLastName = fn.split(separator: " ").last.map { titleCasedName(String($0)) }
        } else {
        out.playerLastName = bestLastName(from: cleaned)
    }

        // Set (generic â€” try to capture big title like "CUP QUEST", "SP AUTHENTIC", etc.)
        // NOTE: must never be the player name; we use cardNumber + name tokens to avoid that.
        out.setName = findSetGeneric(
        in: cleaned,
        company: out.company,
        cardNumber: out.cardNumber,
        playerName: out.fullName
        )

        // If we have a code prefix, infer set (soft)
        if out.setName == nil, let cn = out.cardNumber?.uppercased() {
        if cn.hasPrefix("CQ-") { out.setName = "Cup Quest" }
        if cn.hasPrefix("FWA-") { out.setName = "Future Watch" }
        if cn.hasPrefix("SR-") { out.setName = "Sizzle Reel" }
    }

        return out
    }

    private static func firstCardNumberLike(in lines: [String]) -> String? {
        // Prefer alphanumeric codes like "CQ-8" (Cup Quest), then fallback to "#123"
        let deny = ["COPYRIGHT", "PRINTED", "THE UPPER DECK COMPANY", "NHLPA", "NHL "]

        // SPECIAL CASE: Population Count cards have "PC-X" which OCR often misreads
        // Look for lines containing "POPULATION" or "COUNT" and extract number nearby
        let hasPopulation = lines.contains { $0.uppercased().contains("POPULATION") || $0.uppercased().contains("COUNT") }
        if hasPopulation {
            // Look for "PC" followed by a digit (with or without dash/space)
            for l in lines {
                let up = l.uppercased()
                if deny.contains(where: { up.contains($0) }) { continue }
                // Match "PC-4", "PC 4", "PC4"
                if let m = firstRegexMatch("\\bPC\\s*[-â€“]?\\s*(\\d{1,2})\\b", in: up) {
                    let digits = m.filter { $0.isNumber }
                    if !digits.isEmpty { return "PC-\(digits)" }
                }
            }
        }

        for l in lines {
        let up = l.uppercased()
        if deny.contains(where: { up.contains($0) }) { continue }

        if let code = matchCardNumberCode(in: up) {
            let norm = normalizeCardNumberCode(code)
            let parts = norm.split(separator: "-").map { String($0) }
            let prefix = parts.first ?? ""
            // Avoid single-letter prefixes on the FRONT pass (often OCR noise).
            // Exception: Encore inserts use "E-###".
            if prefix.count <= 1 && prefix != "E" {
                continue
            }
            return norm
    }
    }

        // Fallback: explicit "#123"
        for l in lines {
        let up = l.uppercased()
        if let m = firstRegexMatch("#\\s*\\d{1,4}", in: up) {
            let digits = m.filter { $0.isNumber }
            if !digits.isEmpty { return "#\(digits)" }
    }
    }

        return nil
    }

    private static func matchCardNumberCode(in text: String) -> String? {
        // Examples: "CQ-8", "SP-12", "FWA-3", "A-10"
        // Accept dash or en-dash, also accept optional spaces around dash.
        if let m = firstRegexMatch("\\b[A-Z]{1,4}\\s*[-â€“]\\s*\\d{1,4}\\b", in: text) { return m }
        // Sometimes OCR drops the dash: "CQ 8"
        if let m = firstRegexMatch("\\b[A-Z]{1,4}\\s+\\d{1,4}\\b", in: text) { return m }
        return nil
    }

    private static func normalizeCardNumberCode(_ s: String) -> String {
        let up = s.uppercased()
        .replacingOccurrences(of: "â€“", with: "-")
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // Turn "CQ 8" into "CQ-8"
        let parts = up
        .replacingOccurrences(of: "â€¢", with: " ")
        .split(whereSeparator: { $0 == " " || $0 == "-" })
        .map { String($0) }
        .filter { !$0.isEmpty }

        guard parts.count >= 2 else { return up }
        let prefix = parts[0].filter { $0.isLetter }
        let digits = parts[1].filter { $0.isNumber }
        if prefix.isEmpty || digits.isEmpty { return up }
        return "\(prefix)-\(digits)"
    }

        private static func bestFullName(from lines: [String]) -> String? {
        // Pick the most frequent plausible 2-word name across OCR lines.
        // This fixes cases like "MITCH WARNER" vs "MITCH MARNER" when both appear.
        let denyContains = [
        "UPPER", "DECK", "NHLPA", "NHL", "HOCKEY", "SERIES",
        "YOUNG", "GUNS", "ENCORE", "CUP", "QUEST",
        "AUTHENTIC",
        "COPYRIGHT", "PRINTED", "ALL RIGHTS", "THE UPPER DECK COMPANY",
        "TORONTO", "MAPLE", "LEAFS",
        "VICTORY",
        "BRUINS",
        "OVER",
        "POINTS",
        "RECORDED",
        "CLAIMED",
        "HOME",
        "OVERTIME",
        "JAN"
        ]

        func isCandidate(_ raw: String) -> Bool {
        let up = raw.uppercased()
        if denyContains.contains(where: { up.contains($0) }) { return false }
        if up.rangeOfCharacter(from: .decimalDigits) != nil { return false }
        if up.contains(":") { return false }

        let parts = up
            .replacingOccurrences(of: "â€¢", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).filter { $0.isLetter || $0 == "'" } }
            .filter { !$0.isEmpty }

        if parts.count != 2 { return false }
        if parts.contains(where: { $0.count < 2 }) { return false }
        if parts.contains(where: { !$0.allSatisfy({ $0.isLetter }) }) { return false }
        return true
    }

        var freq: [String: Int] = [:]
        for l in lines {
        let raw = l.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCandidate(raw) else { continue }
        let up = raw.uppercased()
        freq[up, default: 0] += 1
    }

        let sorted = freq.sorted { a, b in
        if a.value != b.value { return a.value > b.value }
        return a.key.count > b.key.count
    }
        return sorted.first?.key
    }

    private static func findSetGeneric(
        in lines: [String],
        company: String?,
        cardNumber: String?,
        playerName: String?
    ) -> String? {
        // Try to capture a real "set" like "Cup Quest" / "Young Guns" / "SP Authentic".
        // Rules:
        // Never return the player's name as the set.
        // Use cardNumber context when helpful (e.g., YG are #201-250 in UD Series 1/2).
        // If we detect "Series 1", format as "Series 1 <SetName>" (as requested).

        let upperLines = lines.map { $0.uppercased() }
        let joined = upperLines.joined(separator: " | ")

        let isSeries1 = joined.contains("SERIES 1") || joined.contains("SERIES1")

        func withSeriesPrefix(_ set: String) -> String {
        isSeries1 ? "Series 1 \(set)" : set
    }

        // 1) Strong keyword detections
        if joined.contains("ENCORE") {
        return withSeriesPrefix("Encore")
    }
        if joined.contains("CUP") && joined.contains("QUEST") {
        return withSeriesPrefix("Cup Quest")
    }
        if joined.contains("SIZZLE") && joined.contains("REEL") {
        return withSeriesPrefix("Sizzle Reel")
    }
        if (joined.contains("YOUNG") && joined.contains("GUN")) || (joined.contains("YOUNG") && joined.contains("GUNS")) {
        return withSeriesPrefix("Young Guns")
    }
        if joined.contains("SP") && joined.contains("AUTHENTIC") {
        return withSeriesPrefix("SP Authentic")
    }
        if (joined.contains("SP") && joined.contains("GAME") && joined.contains("USED")) || joined.contains("SP GAME USED") {
        return withSeriesPrefix("SP Game Used")
    }

        // 2) "Young" alone + UD + #201-250 => Young Guns
        if joined.contains("YOUNG"), (company?.uppercased() == "UPPER DECK") {
        if let cn = cardNumber, let n = parseCardNumberInt(cn), (201...250).contains(n) {
            return withSeriesPrefix("Young Guns")
    }
    }

        // 3) Generic: choose a 2-4 word title-like line, but avoid names and boilerplate
        let denyContains = [
        "UPPER", "DECK", "THE", "COMPANY", "COPYRIGHT", "PRINTED",
        "NHLPA", "NHL", "HOCKEY", "TORONTO", "MAPLE", "LEAFS",
        "HEIGHT", "WEIGHT", "SHOOTS", "BORN", "BIRTH", "MINNEAPOLIS", "MINNESOTA",
        "VICTORY",
        "BRUINS",
        "OVER",
        "POINTS",
        "RECORDED",
        "CLAIMED",
        "HOME",
        "OVERTIME",
        "JAN"
        ]

        let nameTokens: Set<String> = {
        guard let playerName else { return [] }
        let parts = playerName.uppercased().split(separator: " ").map { String($0) }
        return Set(parts.filter { $0.count >= 3 })
        }()

        func isLikelyNameLine(_ up: String) -> Bool {
        // 2-3 words, letters only (common OCR output for a player name)
        let words = up.split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard (2...3).contains(words.count) else { return false }
        // If it matches known name tokens, treat it as a name
        if !nameTokens.isEmpty, words.contains(where: { nameTokens.contains($0) }) {
            return true
    }
        // Otherwise: two long words often indicates a name too
        return words.allSatisfy { $0.count >= 4 }
    }

        func normTitle(_ up: String) -> String {
        // Title case but keep common acronyms
        let parts = up.split(separator: " ").map { String($0) }
        return parts.map { p in
            if ["SP", "NHL", "NHLPA", "OHL", "WHL", "QMJHL"].contains(p) { return p }
            return p.lowercased().prefix(1).uppercased() + p.lowercased().dropFirst()
        }.joined(separator: " ")
    }

        for l in upperLines {
        let up = l.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if up.isEmpty { continue }
        if denyContains.contains(where: { up.contains($0) }) { continue }
        if nameTokens.contains(where: { up.contains($0) }) { continue }
        if isLikelyNameLine(up) { continue }

        // 2-4 words, mostly letters, no digits
        let words = up.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard (2...4).contains(words.count) else { continue }
        guard !up.contains(where: { $0.isNumber }) else { continue }
        return withSeriesPrefix(normTitle(up))
    }

        return nil
    }



    private static func parseCardNumberInt(_ s: String) -> Int? {
        // Accept formats: "#201", "201", "CQ-8" (returns 8), "FWA-3" (returns 3)
        let up = s.uppercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if up.isEmpty { return nil }

        // If alphanumeric code like "CQ-8", take trailing digits
        if let m = firstRegexMatch("\\b\\d{1,4}\\b", in: up) {
        return Int(m)
    }

        // Fallback: strip non-digits
        let digits = up.filter { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

private static func bestLastName(from lines: [String]) -> String? {
        let stop = Set(["UPPER", "DECK", "YOUNG", "GUNS", "YOUNGG", "YOUNGC", "YOUNGGS", "SERIES", "ROOKIE", "RC", "NHL", "RANGERS", "NEW", "YORK", "CCM"])

        var best: String? = nil
        var bestScore = -1

        for l in lines {
        let parts = l
            .replacingOccurrences(of: "â€¢", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        for p in parts {
            let u = p.uppercased()
            guard u.count >= 6 else { continue }
            guard u.allSatisfy({ $0.isLetter }) else { continue }
            guard !stop.contains(u) else { continue }

            let score = u.count
            if score > bestScore {
                bestScore = score
                best = u
            }
    }
    }

        return best.map { titleCasedName($0) }
    }

    static func titleCasedName(_ s: String) -> String {
        s.lowercased()
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
    }

    private static func firstRegexMatch(_ pattern: String, in text: String) -> String? {
        do {
        let re = try NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let m = re.firstMatch(in: text, options: [], range: range),
           let r = Range(m.range, in: text) {
            return String(text[r])
    }
        return nil
        } catch {
        return nil
    }
    }



    /// Detects product-season year on the FRONT (e.g., "2023-24") while trying to avoid false positives
    /// coming from stats tables on the back.
    fileprivate static func findSeasonYear(in lines: [String]) -> String? {
        // Match season formats like 2021-22, 2021â€“22, 2021/22 with optional spaces.
        let yearRx = try! NSRegularExpression(pattern: "\\b(19|20)\\d{2}\\s*[-â€“/]\\s*\\d{2}\\b", options: [])

        func norm(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "â€“", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

        func hasStatsContext(_ idx: Int, _ lines: [String]) -> Bool {
        // If the year is near typical stats headers, it's likely a stats-table year (bad).
        let ctx = [
            idx > 0 ? lines[idx - 1].uppercased() : "",
            lines[idx].uppercased(),
            idx + 1 < lines.count ? lines[idx + 1].uppercased() : "",
            idx + 2 < lines.count ? lines[idx + 2].uppercased() : ""
        ]
        let bad = ["YEAR", "TEAM", "GP", "G", "A", "PTS", "PIM", "PPG", "SHG", "+/-", "NHL SEASON"]
        return ctx.contains(where: { s in bad.contains(where: { s.contains($0) }) })
    }

        var best: (year: String, score: Int)? = nil

        for (idx, l) in lines.enumerated() {
        let up = l.uppercased()

        let matches = yearRx.matches(in: l, range: NSRange(location: 0, length: (l as NSString).length))
        for m in matches {
            let raw = (l as NSString).substring(with: m.range)
            let y = norm(raw)

            var score = 10

            // Strong penalty: looks like a stats row/header context
            if hasStatsContext(idx, lines) { score -= 120 }

            // Additional penalty: year appears on a stats row (often includes many numeric columns).
            // Example: "2023-24 BLACKHAWKS 3 1 0 1 -4 0 0"
            let numberGroups = up.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .filter { !$0.isEmpty }
            if numberGroups.count >= 5 { score -= 160 }


            // Prefer product-line cues typically on the front
            if up.contains("UPPER") && up.contains("DECK") { score += 60 }
            if up.contains("SERIES") { score += 40 }
            if up.contains("HOCKEY") { score += 20 }
            if up.contains("SP") { score += 10 }
            if up.contains("AUTHENTIC") { score += 10 }
            if up.contains("O-PEE-CHEE") || up.contains("OPEE") { score += 10 }

            // Mild preference for modern seasons
            if y.hasPrefix("20") { score += 2 }

            if best == nil || score > best!.score {
                best = (y, score)
            }
    }
    }

        return best?.year
    }
    }


// MARK: Back parsing (robust for hockey cards)

private enum BackOCRParser {

    /// Local wrapper so calls like `regexMatches()` work inside `BackOCRParser`.
    private static func regexMatches(_ pattern: String, in text: String) -> [String] {
        do {
        let re = try NSRegularExpression(pattern: pattern, options: [])
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = re.matches(in: text, options: [], range: range)
        return matches.compactMap { m in
            guard m.range.location != NSNotFound else { return nil }
            return ns.substring(with: m.range)
    }
        } catch {
        return []
    }
    }

    // Compatibility overloads (older call sites)
    static func regexMatches(from text: String, pattern: String) -> [String] {
        return regexMatches(pattern, in: text)
    }

    static func regexMatches(_ text: String, pattern: String) -> [String] {
        return regexMatches(pattern, in: text)
    }

    static func firstRegexMatch(from text: String, pattern: String) -> String? {
        return regexMatches(from: text, pattern: pattern).first
    }

    /// Convenience overload so call sites can use `firstRegexMatch(pattern, in: text)`.
    static func firstRegexMatch(_ pattern: String, in text: String) -> String? {
        return firstRegexMatch(from: text, pattern: pattern)
    }




    // MARK: Heuristics

    /// Keywords that strongly suggest a line is metadata (not a player name).
    /// This prevents cases like "HEIGHT: 5'9\" WEIGHT: 182 LBS." from being selected.
    private static let nonNameKeywords: [String] = [
        "HEIGHT", "WEIGHT", "SHOOTS", "BORN", "BIRTH",
        "LEFT WING", "RIGHT WING", "CENTER", "CENTRE",
        "DEFENSE", "DEFENCE", "GOALIE", "GOALTENDER",
        "CONGRATULATIONS", "AUTHENTIC", "MEMORABILIA", "AUTOGRAPH",
        "SERIES", "UPPER DECK", "HOCKEY", "COPYRIGHT", "PRINTED",
        "ALL RIGHTS RESERVED", "NHLPA", "NHL"
    ]

    /// Returns true when a line looks like a stats/metadata line.
    private static func isMetadataLine(_ s: String) -> Bool {
        let up = s.uppercased()
        if up.contains(":") { return true }
        if up.range(of: "\\d", options: String.CompareOptions.regularExpression) != nil {
        // digits in a supposed name line is a red flag (height/weight, years, serials)
        return true
    }
        for k in nonNameKeywords {
        if up.contains(k) { return true }
    }
        return false
    }


    /// Returns true when a line is very unlikely to be a player name (set/brand/bio/stats).
    private static func isLikelyNonNameLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        // Existing broad heuristics.
        if isMetadataLine(trimmed) { return true }

        let up = trimmed.uppercased()

        // Position or team/position hints (e.g. "CANADIENS/LW").
        if up.contains("/") { return true }

        // Stats/bio lines often contain digits or colons.
        if up.contains(":") { return true }
        if up.rangeOfCharacter(from: .decimalDigits) != nil { return true }

        // Common non-name phrases seen on card backs/sets.
        let denyPhrases: [String] = [
        "YOUNG GUNS",
        "YOUNGG", "YOUNGC", "YOUNGGS", "YOUNGGUNS", "FUTURE WATCH", "SP AUTHENTIC", "UPPER DECK",
        "AUTOGRAPH", "AUTO", "PATCH", "MEMORABILIA", "CONGRATULATIONS",
        "HEIGHT", "WEIGHT", "SHOOTS", "BORN",
        "LEFT WING", "RIGHT WING", "CENTER", "DEFENSE", "DEFENCEMAN", "GOALIE",
        "SERIES", "HOCKEY", "ROOKIE", "RC", "NHLPA", "NHL", "UDC",
        "CUP QUEST", "DAZZLERS", "SIZZLE REEL", "POPULATION COUNT", "POPULATION"
        ]
        for p in denyPhrases {
        if up.contains(p) { return true }
    }

        let words = up.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0) }
        if words.count >= 5 { return true }

        if words.count == 1 {
        let w = words[0]
        let denySingles: Set<String> = ["GUNS","YOUNG","UPPER","DECK","SERIES","AUTHENTIC","FUTURE","WATCH","PATCH","AUTO","AUTOGRAPH","CUP","QUEST"]
        if denySingles.contains(w) { return true }
        if w.count <= 2 { return true }
    }

        return false
    }

    struct Result {
        var fullName: String?
        var lastName: String?
        var year: String?
        var cardNumber: String?
        var company: String?
        var setName: String?
    }

    static func parse(lines: [String], companyHint: String?) -> Result {
        let raw = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let upper = raw.map { $0.uppercased() }

        var out = Result()

        // 1) Name
        if let fn = (findFullName(in: raw) ?? findFullNameFromAdjacentLines(in: raw)) {
        out.fullName = FrontOCRParser.titleCasedName(fn)
        out.lastName = fn.split(separator: " ").last.map { FrontOCRParser.titleCasedName(String($0)) }
        } else {
        out.lastName = findLikelyLastName(in: upper)
    }

        // 2) Year (prefer season)
        out.year = findSeasonYear(in: raw)

        // 3) Company (use hint if available)
        out.company = findCompany(in: upper) ?? (companyHint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? companyHint?.trimmingCharacters(in: .whitespacesAndNewlines) : nil)

        // 4) Card number
        let hasYoung = upper.contains(where: { $0.contains("YOUNG") })
        out.cardNumber = findCardNumber(in: raw, preferYoungGunsRule: hasYoung)


        // Fix common OCR confusion for Tracking Systems inserts: "TS-30" can be read as "IT-1" / "IT-30".
        if let num = out.cardNumber {
        let upNum = num.uppercased().replacingOccurrences(of: " ", with: "")
        let isTrackingSystems = upper.joined(separator: " ").uppercased().contains("TRACKING SYSTEMS")
        if isTrackingSystems, upNum.hasPrefix("IT-") {
            let digits = upNum.replacingOccurrences(of: "IT-", with: "")
            if digits.range(of: #"^\d+$"#, options: String.CompareOptions.regularExpression) != nil {
                out.cardNumber = "TS-\(digits)"
            }
    }
    }


// 5) Set
out.setName = findSet(in: upper, company: out.company, cardNumber: out.cardNumber, playerName: out.fullName ?? out.lastName)

// If this is a Future Watch card and the back only shows a plain number (e.g., "138"),
// normalize it as "FWA-138" to be more useful for eBay/search and to avoid ambiguity.
if let set = out.setName?.uppercased(),
   set.contains("FUTURE WATCH"),
   let cn = out.cardNumber?.trimmingCharacters(in: .whitespacesAndNewlines) {
    let digitsOnly = cn.replacingOccurrences(of: "#", with: "")
        .replacingOccurrences(of: " ", with: "")
    if digitsOnly.range(of: #"^\d{1,4}$"#, options: String.CompareOptions.regularExpression) != nil {
        out.cardNumber = "FWA-\(digitsOnly)"
    }
    }


// If we can detect the Upper Deck Series (1/2) on the back, use it to build the set.
// Example: "Cup Quest" -> "Series 1 Cup Quest"
// If no explicit set is found, default to just "Series X" (not "Upper Deck Series X")
if let series = findUpperDeckSeries(in: upper) {
    if let set = out.setName, !set.isEmpty {
        if !set.lowercased().contains("series") {
        out.setName = "\(series) \(set)"
    }
    } else {
        out.setName = series  // Changed: was "Upper Deck \(series)"
    }
    }

        return out
    }


private static func findUpperDeckSeries(in upperLines: [String]) -> String? {
    // Looks for lines like "2025-26 UPPER DECK SERIES 2 HOCKEY".
    // OCR can drop spaces ("SERIES2") or use roman numerals ("SERIES II").
    for l in upperLines {
        let s = l.replacingOccurrences(of: " ", with: "")
        if l.contains("SERIES 1") || s.contains("SERIES1") || l.contains("SERIES I") { return "Series 1" }
        if l.contains("SERIES 2") || s.contains("SERIES2") || l.contains("SERIES II") { return "Series 2" }
        // Some scans return "S1" / "S2".
        if l.contains("S1") && l.contains("SERIES") { return "Series 1" }
        if l.contains("S2") && l.contains("SERIES") { return "Series 2" }
    }
    return nil
    }

    private static func findCompany(in upperLines: [String]) -> String? {
        if upperLines.contains(where: { $0.contains("UPPER DECK") || ($0.contains("UPPER") && $0.contains("DECK")) }) {
        return "Upper Deck"
    }
        // SP, SP Authentic, SP Game Used are all Upper Deck brands
        if upperLines.contains(where: { $0.contains("SP AUTHENTIC") || $0.contains("SP GAME USED") }) {
            return "Upper Deck"
        }
        // Standalone "SP" (common on card fronts) - but avoid false positives like "TIPS"
        if upperLines.contains(where: { line in
            // Match "SP" as a standalone word
            let pattern = #"\bSP\b"#
            return line.range(of: pattern, options: .regularExpression) != nil
        }) {
            return "Upper Deck"
        }
        if upperLines.contains(where: { $0.contains("TOPPS") }) { return "Topps" }
        if upperLines.contains(where: { $0.contains("PANINI") }) { return "Panini" }
        if upperLines.contains(where: { $0.contains("O-PEE-CHEE") || $0.contains("OPC") }) { return "Upper Deck" }
        return nil
    }

    private static func findSet(in upperLines: [String], company: String?, cardNumber: String?, playerName: String?) -> String? {
        // Direct keyword wins
        let hasSPAuthentic = upperLines.contains(where: { $0.contains("SP AUTHENTIC") })
        let hasFutureWatch = upperLines.contains(where: { $0.contains("FUTURE WATCH") })

        // Combine when both appear (common on Future Watch backs)
        if hasSPAuthentic && hasFutureWatch { return "SP Authentic Future Watch" }

        if upperLines.contains(where: { $0.contains("ENCORE") }) { return "Encore" }
        if upperLines.contains(where: { $0.contains("CUP QUEST") }) { return "Cup Quest" }
        if upperLines.contains(where: { $0.contains("SIZZLE REEL") }) { return "Sizzle Reel" }
        if upperLines.contains(where: { $0.contains("DAZZLERS") || $0.contains("DAZZLER") }) { return "Dazzlers" }
        
        // MVP: chercher "MVP" (souvent en bas: "2025-26 MVP HOCKEY")
        let hasMVP = upperLines.contains(where: { $0.contains("MVP") })
        let hasHockey = upperLines.contains(where: { $0.contains("HOCKEY") })
        
        if hasMVP {
            // Vérifier que c'est bien Upper Deck MVP (pas un autre MVP)
            let comp = (company ?? "").uppercased()
            if comp.contains("UPPER") || comp.contains("DECK") {
                // Si on a MVP + HOCKEY → certainement MVP
                if hasHockey {
                    return "MVP"
                }
                // Si on a juste MVP + numéro simple (pas préfixé) → probablement MVP
                // MVP utilise des numéros simples 1-250, pas de préfixes
                if let cn = cardNumber, !cn.isEmpty {
                    let hasPrefix = cn.contains("-")
                    let isSimpleNumber = !hasPrefix && (Int(cn.replacingOccurrences(of: "#", with: "")) != nil)
                    if isSimpleNumber {
                        return "MVP"
                    }
                }
            }
        }
        
        // Population Count: chercher "POPULATION" ET "COUNT" séparément car OCR les sépare souvent
        let hasPopulation = upperLines.contains(where: { $0.contains("POPULATION") })
        let hasCount = upperLines.contains(where: { $0.contains("COUNT") })
        if hasPopulation && hasCount { return "Population Count" }
        if hasSPAuthentic { return "SP Authentic" }
        if upperLines.contains(where: { $0.contains("SP GAME USED") }) { return "SP Game Used" }
        if hasFutureWatch { return "Future Watch" }

        // If we have a code prefix, infer set (ex: "CQ-8" => Cup Quest)
        if let cn = cardNumber?.uppercased() {
        if cn.hasPrefix("CQ-") { return "Cup Quest" }
        if cn.hasPrefix("FWA-") { return "Future Watch" }
        if cn.hasPrefix("SR-") { return "Sizzle Reel" }
        if cn.hasPrefix("DZ-") { return "Dazzlers" }
        if cn.hasPrefix("PC-") { return "Population Count" }
    }

        let hasYoung = upperLines.contains(where: { $0.contains("YOUNG") })
        let hasGuns = upperLines.contains(where: { $0.contains("GUN") || $0.contains("GUNS") })
        if hasYoung && hasGuns { return "Young Guns" }

        // Fallback: OCR often captures only "YOUNG".
        // For Upper Deck Series 1/2, Young Guns are commonly numbered 201-250.
        if hasYoung {
        let comp = (company ?? "").uppercased()
        if comp.contains("UPPER") || comp.contains("DECK") {
            if let n = parseCardNumberInt(cardNumber), (201...250).contains(n) {
                return "Young Guns"
            }
    }
    }

        // Generic heuristic: pick a short "title" phrase that isn't brand/legal/team.
        let deny = [
        "UPPER", "DECK", "THE UPPER DECK COMPANY", "COPYRIGHT", "PRINTED",
        "ALL RIGHTS", "RESERVED", "NHLPA", "NHL", "HOCKEY", "SERIES",
        "TORONTO", "MAPLE", "LEAFS",
        "NO", "YES", "THE", "WIND" // Common OCR noise words
        ]

        // Never allow the set to be (or contain) the player name.
        let playerUpper = playerName?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let playerTokens: Set<String> = Set(playerUpper.split(separator: " ").map { String($0) }.filter { $0.count >= 3 })

        func looksLikeNameLine(_ up: String) -> Bool {
        let words = up
            .replacingOccurrences(of: "â€¢", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty }
        if words.count == 2 || words.count == 3 {
            // Typical name: 2-3 alphabetic words, each 3+ chars
            if words.allSatisfy({ $0.count >= 3 && $0.allSatisfy({ $0.isLetter }) }) {
                return true
            }
    }
        return false
    }

        var best: (text: String, score: Int)? = nil
        for l in upperLines {
        let up = l.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if up.isEmpty { continue }

        // Avoid selecting the player name as the set.
        if !playerUpper.isEmpty {
            if up == playerUpper { continue }
            if looksLikeNameLine(up) { continue }
            if playerTokens.contains(where: { up.contains($0) }) { continue }
    }

        if deny.contains(where: { up.contains($0) }) { continue }
        if containsAnyTeamCityWord(up) { continue } // avoid team/city lines being picked as set (e.g., CAROLINA HURRICANES)
        if up.rangeOfCharacter(from: .decimalDigits) != nil { continue }
        if up.contains(":") { continue }
        
        // Reject nonsensical phrases (common OCR garbage)
        let nonsensePhrases = ["NO WIND", "YES NO", "THE THE", "AND OR", "LEFT RIGHT", "UP DOWN"]
        if nonsensePhrases.contains(where: { up.contains($0) }) { continue }

        let words = up
            .replacingOccurrences(of: "â€¢", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty }

        if words.count < 2 || words.count > 4 { continue }
        if words.contains(where: { $0.count < 3 }) { continue }
        if words.contains(where: { !$0.allSatisfy({ $0.isLetter }) }) { continue }

        let score = words.reduce(0) { $0 + $1.count }
        if best == nil || score > best!.score {
            best = (up, score)
    }
    }

        if let raw = best?.text {
        return FrontOCRParser.titleCasedName(raw)
    }

        return nil
    }

    fileprivate static func findSeasonYear(in lines: [String]) -> String? {
        // Prefer the product season year (often printed with the product line like
        // "2025-26 UPPER DECK SERIES 1 HOCKEY") and avoid the stats table year
        // under the "YEAR / TEAM / GP ..." section.
        let yearRx = try! NSRegularExpression(pattern: "\\b(19|20)\\d{2}\\s*[-â€“/]\\s*\\d{2}\\b", options: [])

        func norm(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "")
         .replacingOccurrences(of: "â€“", with: "-")
         .replacingOccurrences(of: "/", with: "-")
    }
    
        // PRIORITY RULE: If we find a year on the same line as major card manufacturers, use it immediately!
        // This is the most reliable indicator of the card's actual year.
        // IMPORTANT: Use the LAST year found on the line (in case stats year appears before product year)
        let manufacturers = [
            ["UPPER", "DECK"],
            ["PANINI"],
            ["TOPPS"],
            ["O-PEE-CHEE", "OPC"],
            ["LEAF"],
            ["FLEER"],
            ["DONRUSS"]
        ]
        
        for l in lines {
            let up = l.uppercased()
            
            // Check if line contains any manufacturer name
            for mfg in manufacturers {
                if mfg.allSatisfy({ up.contains($0) }) {
                    let matches = yearRx.matches(in: l, range: NSRange(location: 0, length: (l as NSString).length))
                    // Use LAST match, not first (product year usually comes after stats year if both present)
                    if let lastMatch = matches.last {
                        let raw = (l as NSString).substring(with: lastMatch.range)
                        return norm(raw)
                    }
                }
            }
        }
        
        // If no year found on manufacturer line, fall back to scoring system

        func hasStatsContext(_ idx: Int, _ lines: [String]) -> Bool {
        // If the year is near a stats header, it's likely the season stats year (bad).
        let ctx = [
            idx > 0 ? lines[idx - 1].uppercased() : "",
            lines[idx].uppercased(),
            idx + 1 < lines.count ? lines[idx + 1].uppercased() : "",
            idx + 2 < lines.count ? lines[idx + 2].uppercased() : ""
        ]
        let bad = ["YEAR", "TEAM", "GP", "PTS", "PIM", "PPG", "NHL SEASON", "+/-", "OHL", "AHL", "QMJHL", "WHL", "SEASON"]
        return ctx.contains(where: { s in bad.contains(where: { s.contains($0) }) })
    }
    
    func isStatsRow(_ line: String) -> Bool {
        // Detect if line looks like a stats row: has year + multiple separate numbers (GP, G, A, PTS, etc.)
        let up = line.uppercased()
        
        // If line contains stats column headers, it's definitely a stats context
        let statsHeaders = ["GP", "PTS", "PIM", "+/-", "PPG"]
        if statsHeaders.filter({ up.contains($0) }).count >= 2 {
            return true
        }
        
        // Common junior/minor league teams that appear in stats rows
        let minorTeams = ["GUELPH", "KITCHENER", "LONDON", "WINDSOR", "SAULT", "SUDBURY", "BARRIE", 
                          "PETERBOROUGH", "OSHAWA", "NIAGARA", "KINGSTON", "OTTAWA", "HAMILTON",
                          "MISSISSAUGA", "BRAMPTON", "RANGERS", "BATTALION", "STEELHEADS"]
        
        // NHL team names (often appear in stats rows for current season)
        let nhlTeams = ["DUCKS", "BRUINS", "SABRES", "FLAMES", "HURRICANES", "BLACKHAWKS",
                        "AVALANCHE", "BLUE JACKETS", "STARS", "RED WINGS", "OILERS", "PANTHERS",
                        "KINGS", "WILD", "CANADIENS", "PREDATORS", "DEVILS", "ISLANDERS", "RANGERS",
                        "SENATORS", "FLYERS", "PENGUINS", "SHARKS", "KRAKEN", "BLUES",
                        "LIGHTNING", "MAPLE LEAFS", "CANUCKS", "GOLDEN KNIGHTS", "CAPITALS", "JETS"]
        
        // If line contains a team name, likely a stats row
        if minorTeams.contains(where: { up.contains($0) }) {
            return true
        }
        if nhlTeams.contains(where: { up.contains($0) }) {
            return true
        }
        
        // Count separate numeric tokens (stats are usually 5+ numbers: GP, G, A, PTS, +/-, PIM, PPG)
        let tokens = line.split(whereSeparator: { !$0.isNumber }).filter { !$0.isEmpty }
        let numbers = tokens.filter { Int($0) != nil || $0.contains("-") }
        
        // If line has 5+ numbers, it's likely a stats row
        if numbers.count >= 5 {
            return true
        }
        
        return false
    }

        var best: (year: String, score: Int)? = nil

        for (idx, l) in lines.enumerated() {
        let up = l.uppercased()

        let matches = yearRx.matches(in: l, range: NSRange(location: 0, length: (l as NSString).length))
        for m in matches {
            let raw = (l as NSString).substring(with: m.range)
            let y = norm(raw)

            var score = 10

            // Strong penalties: years in stats table context
            if hasStatsContext(idx, lines) { score -= 200 }
            
            // CRITICAL: Detect if year appears in actual stats row (year + team + numbers)
            if isStatsRow(l) { score -= 500 }

            // Extra penalty if the same line contains an NHL team/city (usually a stats row)
            if teamCityWords.contains(where: { up.contains($0) }) { score -= 100 }

            // Prefer product-line cues (increased bonuses to ensure product year wins)
            if up.contains("UPPER") && up.contains("DECK") { score += 150 }
            if up.contains("SERIES") { score += 80 }
            if up.contains("HOCKEY") { score += 50 }
            if up.contains("SP") { score += 30 }
            if up.contains("AUTHENTIC") { score += 20 }
            if up.contains("GAME") && up.contains("USED") { score += 20 }
            
            // Strong bonus for product line with multiple keywords
            if up.contains("UPPER") && up.contains("DECK") && up.contains("SERIES") { score += 100 }
            
            // Bonus for years in last 30% of lines (product info typically at bottom)
            if lines.count > 5 && idx >= Int(Double(lines.count) * 0.7) { score += 50 }
            
            // Mild preference for modern cards
            if y.hasPrefix("20") { score += 2 }

            if best == nil || score > best!.score {
                best = (y, score)
            }
    }
    }

        return best?.year
    }

private static func findCardNumber(in lines: [String], preferYoungGunsRule: Bool) -> String? {
        // Prefer explicit alphanumeric codes like "CQ-8" (Cup Quest), then fallback to "#123"/numeric.
        // Important: avoid false positives from bio lines like "BORN: JUNE 1, 2004" (e.g., "JUNE-1").
        let deny = [
        "COPYRIGHT", "PRINTED", "THE UPPER DECK COMPANY", "NHLPA", "NHL ",
        "BORN", "BIRTH", "HEIGHT", "WEIGHT", "SHOOTS"
        ]

        let denyPrefixes: Set<String> = [
        // Months / date-like tokens that can look like codes after OCR (JUNE-1, JULY-4, etc.)
        "JAN", "FEB", "MAR", "APR", "APRI", "APRIL", "MAY", "JUN", "JUNE", "JUL", "JULY", "AUG",
        "SEP", "SEPT", "OCT", "NOV", "DEC",
        // Bio lines like "from 2022" can turn into FROM-2022
        "FROM",
            // NHL/team codes (avoid picking game scores like WILD-5)
            "WILD",
            "NYR",
            "NYI",
            "NJD",
            "LAK",
            "SJS",
            "SEA",
            "UTA",
            "VGK",
            "WSH",
            "WPG",
            "STL",
            "TBL",
            "MTL",
            "TOR",
            "OTT",
            "BOS",
            "BUF",
            "CHI",
            "COL",
            "CBJ",
            "CAR",
            "CGY",
            "DAL",
            "DET",
            "EDM",
            "FLA",
            "MIN",
            "NSH",
            "ANA",
            "ARI",
            "PIT",
            "PHI"
        ]

        // Young Guns (and most base cards) are numeric on the back.
        // OCR sometimes fabricates false "codes" from stat tables (ex: "A-7").
        // When we think it's Young Guns, we intentionally SKIP the code-first logic.
        if !preferYoungGunsRule {

        // âœ… RÃ¨gle Cardia: le numÃ©ro de carte est TOUJOURS sur le dos, et il peut Ãªtre n'importe oÃ¹.
        // On scanne donc toutes les lignes, puis on classe les candidats (au lieu de prendre le "premier match").

        let joinedUpper = lines.joined(separator: " ").uppercased()

        // Indices de "code" attendus selon le set dÃ©tectable sur le dos.
        var expectedPrefixes: [String] = []
        if joinedUpper.contains("SYSTEMS") && (joinedUpper.contains("TRACK") || joinedUpper.contains("TRAC")) { expectedPrefixes.append("TS") }
        if joinedUpper.contains("CUP") && joinedUpper.contains("QUEST") { expectedPrefixes.append("CQ") }
        if joinedUpper.contains("ENCORE") { expectedPrefixes.append("E") }
        if joinedUpper.contains("POPULATION") && joinedUpper.contains("COUNT") { expectedPrefixes.append("PC") }
        if joinedUpper.contains("DAZZLERS") || joinedUpper.contains("DAZZLER") { expectedPrefixes.append("DZ") }
        if joinedUpper.contains("SIZZLE") && joinedUpper.contains("REEL") { expectedPrefixes.append("SR") }
        if joinedUpper.contains("FUTURE") && joinedUpper.contains("WATCH") { expectedPrefixes.append("FW") }
        if joinedUpper.contains("PORTRAITS") || joinedUpper.contains("PORTRAIT") { expectedPrefixes.append("P") }

        struct CodeCandidate {
            let norm: String
            let prefix: String
            let digits: String
            let score: Int
    }

        func scoreCandidate(prefix: String, digits: String, lineIndex: Int) -> Int {
            var score = 0

            // Plus c'est tÃ´t dans la liste OCR, mieux c'est (souvent en haut du dos, mais PAS une rÃ¨gle stricte).
            score += max(0, 220 - (lineIndex * 4))

            // PrÃ©fÃ©rence pour des prÃ©fixes 2-3 lettres (ex: TS, CQ, UD, etc.)
            if prefix.count == 2 { score += 180 }
            else if prefix.count == 3 { score += 140 }
            else if prefix.count == 4 { score += 80 }
            else if prefix.count == 1 { score += 10 } // rare, mais possible (ex: Encore E-73)

            // PrÃ©fÃ©rence pour 2-3 chiffres (TS-30 > C-8 dans la plupart des inserts)
            if digits.count == 2 { score += 140 }
            else if digits.count == 3 { score += 120 }
            else if digits.count == 1 { score -= 40 }
            else if digits.count == 4 { score -= 20 } // souvent un faux positif / annÃ©e

            // Bonus massif si le prÃ©fixe correspond au set dÃ©tectÃ© sur le dos.
            if expectedPrefixes.contains(prefix) { score += 520 }

            // PÃ©nalitÃ©s anti faux positifs (dates, Ã©quipes, etc.)
            if denyPrefixes.contains(prefix) || prefix.hasPrefix("APR") { score -= 800 }

            // Ã‰vite FROM-2022 / etc.
            if digits.count == 4, let y = Int(digits), (1900...2099).contains(y) { score -= 800 }

            return score
    }

        var candidates: [CodeCandidate] = []

        for (idx, l) in lines.enumerated() {
            let up = l.uppercased()
            if deny.contains(where: { up.contains($0) }) { continue }

            // Collecte: "TS-30", "CQ-8", "E-73", etc.
            let patterns = [
                "\\b[A-Z]{1,4}\\s*[-â€“]\\s*[0-9O]{1,4}\\b",
                "\\b[A-Z]{1,4}\\s+[0-9O]{1,4}\\b"
            ]

            for pat in patterns {
                for hit in regexMatches(pat, in: up) {
                    let norm = normalizeCardNumberCode(hit)

                    let parts = norm.split(separator: "-").map { String($0) }
                    let prefix = (parts.first ?? "").uppercased()
                    var digits = (parts.last ?? "").uppercased()

                    // Normalise confusion OCR: O -> 0 dans le segment numÃ©rique.
                    digits = digits.replacingOccurrences(of: "O", with: "0")

                    // Filtre prÃ©liminaire
                    if prefix.isEmpty || digits.isEmpty { continue }

                    // Ã‰vite les faux "A-7" / "G-1" provenant de tables de stats.
                    if prefix.count <= 1 {
                        let allowedSingleLetter: Set<String> = ["E"]
                        if !allowedSingleLetter.contains(prefix) { continue }
                    }

                    if digits.range(of: #"^\d+$"#, options: String.CompareOptions.regularExpression) == nil { continue }

                    let s = scoreCandidate(prefix: prefix, digits: digits, lineIndex: idx)
                    candidates.append(.init(norm: "\(prefix)-\(digits)", prefix: prefix, digits: digits, score: s))
                }
            }
    }

        // Choisit le meilleur candidat (score max)
        if let best = candidates.max(by: { $0.score < $1.score }) {
            return best.norm
    }
    }



// Goal: pick the *card number*, not an address (5830), year (2024), stats, or serial (/100).
        // We use a simple scoring system that heavily prefers:
        // explicit "#101" patterns
        // standalone 1-3 digit lines near the top
        // and rejects big 4+ digit values.

        // 1) Explicit "#123" anywhere
        for l in lines {
        let up = l.uppercased()
        if let m = firstRegexMatch("#\\s*\\d{1,4}", in: up) {
            let digits = m.filter { $0.isNumber }
            if let v = Int(digits), v > 0, v < 2000 {
                return "\(v)"
            }
    }
    }

        let badLineKeywords = [
        "HEIGHT", "WEIGHT", "SHOOTS", "BORN", "BIRTH",
        "GP", "PTS", "PIM", "PPG", "SHG", "SOG", "+/-",
        "CARLSBAD", "CAMINO", "REAL", "CA ", "CALIFORNIA", "PRINTED",
        "ALL RIGHTS", "COPYRIGHT", "UPPER DECK", "UDC", "NHLPA"
        ]
        
        // 🛡️ PROTECTION: Filtrer les patterns de mesure de hauteur pour éviter de confondre "6'2" avec #6
        let heightPatterns = [
            #"\b[5-7]\'[0-9]+"#,  // 6'2", 5'11", 7'0"
            #"\b[5-7]\s*\'\s*[0-9]+"#,  // 6 ' 2 ", 5 ' 11 "
            #"\b[5-7]FT"#  // 6FT, 7FT
        ]

        let window = Array(lines.prefix(60))


        // Quick win: card number is very often a standalone number near the very top (e.g. "207" on Young Guns).
        // If we see a clean standalone 2-4 digit number early, take it.
        for (i, l) in lines.prefix(12).enumerated() {
        let raw = l.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { continue }
        if firstRegexMatch(#"^\d{2,4}$"#, in: raw) != nil, let v = Int(raw) {
            if (i <= 3) || v >= 100 {
                if !preferYoungGunsRule || (v >= 1 && v <= 799) {
                    return "\(v)"
                }
            }
    }
    }

        func looksLikeYearLine(_ raw: String) -> Bool {
        // "2025-26" or "2024-25" etc.
        if firstRegexMatch(#"\b20\d{2}[-â€“]\d{2}\b"#, in: raw) != nil { return true }
        if firstRegexMatch(#"\b20\d{2}\b"#, in: raw) != nil && raw.contains("-") { return true }
        return false
    }


        struct Candidate {
        let value: Int
        let score: Int
    }

        var best: Candidate? = nil

        func isYear(_ v: Int) -> Bool {
        return (v >= 1900 && v <= 2099)
    }

        for idx in window.indices {
        let raw = window[idx].trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { continue }
        let up = raw.uppercased()

        if badLineKeywords.contains(where: { up.contains($0) }) { continue }
        if up.contains("/") { continue } // usually serial like 029/100
        
        // 🛡️ PROTECTION: Skip lines containing height measurements (6'2", 5'11", etc.)
        var containsHeightPattern = false
        for pattern in heightPatterns {
            if firstRegexMatch(pattern, in: up) != nil {
                containsHeightPattern = true
                break
            }
        }
        if containsHeightPattern { continue }

        // Prefer standalone digits (ex: "451" or "101")
        let isStandaloneNumber = firstRegexMatch("^\\d{1,3}$", in: up) != nil
        let isNoPattern = firstRegexMatch("\\bNO\\.?\\s*\\d{1,4}\\b", in: up) != nil

        // Extract numeric tokens, but cap to 1-3 digits to avoid 5830 and years.
        let matches = regexMatches("\\b\\d{1,3}\\b", in: up)
        if matches.isEmpty { continue }

        for m in matches {
            guard let v = Int(m), v > 0 else { continue }
            if isYear(v) { continue }

            // Card numbers rarely exceed 999; rejecting > 999 eliminates "5830".
            if v > 999 { continue }

            var score = 0
            // earlier lines = higher score
            score += max(0, 120 - (idx * 3))

            if isStandaloneNumber { score += 200 }
            if isNoPattern { score += 120 }

            // Young Guns rule: card numbers are usually 200+
            if preferYoungGunsRule {
                if v >= 200 { score += 140 } else { score -= 60 }
            } else {
                // Avoid jersey numbers / weights (often < 100) unless standalone
                if v >= 100 { score += 60 } else { score -= 30 }
            }

            let candidate = Candidate(value: v, score: score)
            if best == nil || candidate.score > best!.score {
                best = candidate
            }
    }
    }

        guard let chosen = best else { return nil }
        return "\(chosen.value)"
    }



    // MARK: Back OCR: player name extraction

    private static let backNameBadContains: [String] = [
    "HEIGHT", "WEIGHT", "SHOOTS", "BORN", "BIRTH",
    "NHL", "SEASON", "ROOKIE", "RC", "STATS", "CAREER", "BIO",
    "GP", "PTS", "+/-", "PIM", "PPG", "G", "A", "P",
    "UPPER", "DECK", "SERIES", "YOUNG", "GUNS", "ENCORE", "CUP", "QUEST",
    "VICTORY", "OVER", "HOME", "RECORDED", "FINISHED", "POINTS", "CLAIMED"
]

    // MARK: Helpers (name parsing)
    private static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        // Normalize common punctuation variants that Vision OCR often outputs
        t = t.replacingOccurrences(of: "â€™", with: "'")
        t = t.replacingOccurrences(of: "â€˜", with: "'")
        t = t.replacingOccurrences(of: "â€", with: "-")
        t = t.replacingOccurrences(of: "â€‘", with: "-")
        t = t.replacingOccurrences(of: "â€“", with: "-")
        t = t.replacingOccurrences(of: "â€”", with: "-")
        // Collapse whitespace
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: String.CompareOptions.regularExpression)
        return t
    }

    private static func badContains(_ textUpper: String, anyOf words: [String]) -> Bool {
        for w in words {
        if textUpper.contains(w) { return true }
    }
        return false
    }

    private static func badContains(_ textUpper: String, anyOf words: Set<String>) -> Bool {
        for w in words {
        if textUpper.contains(w) { return true }
    }
        return false
    }

private static func looksLikePlayerNameLine(_ line: String) -> Bool {
    if containsCyrillic(line) { return false }
    let up = normalize(line).uppercased()

    // Must have 2-3 alphabetic tokens, each reasonably long
    let toks = up
        .replacingOccurrences(of: "â€™", with: "'")
        .split { !$0.isLetter && $0 != "'" && $0 != "-" }
        .map(String.init)
        .filter { !$0.isEmpty }

    if toks.count < 2 || toks.count > 3 { return false }
    if toks.contains(where: { $0.count < 3 }) { return false }

    // Exclude obvious non-name vocabulary
    if badContains(up, anyOf: backNameBadContains) { return false }
    if containsAnyTeamCityWord(up) { return false }

    // Exclude position tokens (C/LW/RW/D/G etc) embedded
    let posTokens: Set<String> = ["C", "LW", "RW", "D", "LD", "RD", "G", "GK", "F"]
    if toks.contains(where: { posTokens.contains($0) }) { return false }

    return true
    }

private static let teamCityWords: Set<String> = [
        "NEW", "YORK", "RANGERS", "CANADIENS", "MONTREAL", "MONTRÃ‰AL", "MAPLE", "LEAFS",
        "BRUINS", "BLACKHAWKS", "AVALANCHE", "OILERS", "FLAMES", "SENATORS", "JETS",
        "PANTHERS", "LIGHTNING", "PENGUINS", "CAPITALS", "ISLANDERS", "DEVILS", "KINGS",
        "DUCKS", "SHARKS", "STARS", "WILD", "SABRES", "BLUES", "PREDATORS", "KRAKEN",
        "HURRICANES", "COYOTES", "UTAH", "VEGAS", "GOLDEN", "KNIGHTS",
        "TORONTO", "BOSTON", "CHICAGO", "COLORADO", "EDMONTON", "CALGARY", "OTTAWA",
        "WINNIPEG", "FLORIDA", "TAMPA", "PITTSBURGH", "WASHINGTON", "ANAHEIM", "SAN", "JOSE",
        "DALLAS", "MINNESOTA", "BUFFALO", "ST", "LOUIS", "NASHVILLE", "SEATTLE", "CAROLINA",
        "ARIZONA", "LOS", "ANGELES"
    ]

    private static func alphaKey(_ s: String) -> String {
        // Keep only letters (A-Z) for robust matching when OCR inserts punctuation like B'LUESÂ®
        let up = s.uppercased()
        let filtered = up.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return String(String.UnicodeScalarView(filtered))
    }

    fileprivate static func containsAnyTeamCityWord(_ upperText: String) -> Bool {
        let a = alphaKey(upperText)
        for w in teamCityWords {
        if a.contains(alphaKey(w)) { return true }
    }
        return false
    }

    private static let positionCodes: Set<String> = ["LW","RW","C","D","LD","RD","G","L","R","W"]

    private static func surnameKey(_ s: String) -> String {
        return s.uppercased()
        .replacingOccurrences(of: "â€™", with: "")
        .replacingOccurrences(of: "'", with: "")
        .replacingOccurrences(of: " ", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Simple similarity for OCR slips like WARNER vs MARNER
    private static func isSimilarSurname(_ a: String, _ b: String) -> Bool {
        let aa = surnameKey(a)
        let bb = surnameKey(b)
        if aa == bb { return true }

        let dist = levenshteinDistance(aa, bb)
        let maxLen = max(aa.count, bb.count)

        // Allow a bit more tolerance: OCR often swaps 1-2 letters in surnames (e.g., SNUGGERUD -> SNUCCERUD)
        if dist <= 1 { return true }
        if maxLen <= 10 && dist <= 2 { return true }
        return false
    }

    private static func levenshteinDistance(_ s: String, _ t: String) -> Int {
        let a = Array(s)
        let b = Array(t)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var prev = Array(0...b.count)
        var cur = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
        cur[0] = i
        for j in 1...b.count {
            let cost = (a[i - 1] == b[j - 1]) ? 0 : 1
            cur[j] = min(
                prev[j] + 1,        // deletion
                cur[j - 1] + 1,     // insertion
                prev[j - 1] + cost  // substitution
            )
    }
        prev = cur
    }
        return prev[b.count]
    }

        private static func tokenizeBackName(_ line: String) -> (first: String, last: String, fullUpper: String)? {
        // Convert separators (â€¢, Â·, Â®, etc.) to spaces and keep only letters/spaces.
        // This helps when OCR produces: "JIMMY SNUGGERUD â€¢ BLUESÂ®" or similar.
        let upper = line.uppercased()
        let cleaned = upper
        .replacingOccurrences(of: "â€¢", with: " ")
        .replacingOccurrences(of: "Â·", with: " ")
        .replacingOccurrences(of: "Â®", with: " ")
        .replacingOccurrences(of: "Â©", with: " ")
        .replacingOccurrences(of: "|", with: " ")
        .replacingOccurrences(of: "â€”", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        let onlyLetters = cleaned
        .map { ch -> Character in
            if ch.isLetter || ch == " " { return ch }
            return " "
    }
        let parts = String(onlyLetters)
        .split(separator: " ", omittingEmptySubsequences: true)
        .map(String.init)
        .filter { $0.count >= 2 }
        guard parts.count >= 2 else { return nil }

        // Drop trailing tokens that are clearly not part of a name (team/city words, position codes).
        var words = parts
        while words.count >= 3 {
        let tail = words.last ?? ""
        if teamCityWords.contains(tail) || positionCodes.contains(tail) {
            words.removeLast()
            continue
    }
        break
    }

        // Handle common patterns:
        // "FIRST LAST"
        // "FIRST LAST TEAM"  (team already removed above)
        // "FIRST MIDDLE LAST" (keep middle as part of last name to avoid losing compound last names)
        if words.count == 2 {
        let first = words[0].capitalized
        let last = words[1].capitalized
        let full = "\(first) \(last)"
        return (first: first, last: last, fullUpper: full.uppercased())
    }

        if words.count == 3 {
        // If the 3rd token still looks like noise (rare), fall back to FIRST + SECOND.
        // Otherwise treat as FIRST + "SECOND THIRD" (compound last name).
        let first = words[0].capitalized
        let second = words[1].capitalized
        let third = words[2].capitalized
        let full1 = "\(first) \(second)"
        let full2 = "\(first) \(second) \(third)"
        if teamCityWords.contains(words[2]) || positionCodes.contains(words[2]) {
            return (first: first, last: second, fullUpper: full1.uppercased())
        } else {
            return (first: first, last: "\(second) \(third)", fullUpper: full2.uppercased())
    }
    }

        // If we still have 4+ tokens, use FIRST + last two tokens (best compromise).
        let first = words[0].capitalized
        let last = words.suffix(2).map { $0.capitalized }.joined(separator: " ")
        let full = "\(first) \(last)"
        return (first: first, last: last, fullUpper: full.uppercased())
    }


    private static func isBackNameCandidate(_ raw: String) -> (first: String, last: String, fullUpper: String)? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = tokenizeBackName(t) else { return nil }

        if isLikelyNonNameLine(t) { return nil }

        let up = t.uppercased()
        if backNameBadContains.contains(where: { up.contains($0) }) { return nil }
        if parts.first.count < 3 { return nil }
        if parts.last.replacingOccurrences(of: " ", with: "").count < 3 { return nil }

        // Reject obvious team/city words
        if teamCityWords.contains(parts.first) { return nil }
        if teamCityWords.contains(parts.last) { return nil }
        if parts.last.split(separator: " ").contains(where: { teamCityWords.contains(String($0)) }) { return nil }

        // Letters only (allow apostrophes)
        let okWord: (String) -> Bool = { w in
        let s = w.replacingOccurrences(of: "â€™", with: "").replacingOccurrences(of: "'", with: "")
        return !s.isEmpty && s.allSatisfy({ $0.isLetter })
    }
        if !okWord(parts.first) { return nil }
        if !parts.last.split(separator: " ").allSatisfy({ okWord(String($0)) }) { return nil }

        return parts
    }

    private static func findFullName(in lines: [String]) -> String? {
        // We may see multiple noisy variants (ex: "MITCH WARNER" + "MICK MARNER").
        // Strategy:
        //  1) Collect candidate (first,last) pairs.
        //  2) Cluster last names that are "very similar" (OCR slips).
        //  3) Pick the strongest cluster by total frequency.
        //  4) Within that cluster, pick the most frequent full name.

        struct Cand {
        let first: String
        let last: String
        let fullUpper: String
    }

        var cands: [Cand] = []
        for l in lines {
        if let parts = isBackNameCandidate(l) {
            cands.append(Cand(first: parts.first, last: parts.last, fullUpper: parts.fullUpper))
    }
    }

        guard !cands.isEmpty else { return nil }

        // Frequency by last name (as written)
        var lastFreq: [String: Int] = [:]
        var lastDisplay: [String: String] = [:]
        for c in cands {
        let k = surnameKey(c.last)
        lastFreq[k, default: 0] += 1
        lastDisplay[k] = c.last
    }

        // Cluster similar last names (WARNER vs MARNER)
        let keys = Array(lastFreq.keys)
        var clusters: [[String]] = []
        var used = Set<String>()
        for k in keys {
        if used.contains(k) { continue }
        used.insert(k)
        var cluster = [k]
        for other in keys where !used.contains(other) {
            if isSimilarSurname(lastDisplay[k] ?? k, lastDisplay[other] ?? other) {
                cluster.append(other)
                used.insert(other)
            }
    }
        clusters.append(cluster)
    }

        // Choose best cluster by total freq
        func clusterScore(_ cl: [String]) -> Int { cl.reduce(0) { $0 + (lastFreq[$1] ?? 0) } }
        let bestCluster = clusters.max(by: { clusterScore($0) < clusterScore($1) }) ?? []

        // Build full-name frequencies within the chosen cluster
        let allowed = Set(bestCluster)
        var fullFreq: [String: Int] = [:]
        for c in cands {
        if allowed.contains(surnameKey(c.last)) {
            fullFreq[c.fullUpper, default: 0] += 1
    }
    }

        // Pick best full name (avoid OCR typos by preferring surnames that appear elsewhere in the OCR lines)
        let allAlpha = alphaKey(lines.joined(separator: " "))

        func countOccurrences(_ needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange: Range<String.Index>? = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = r.upperBound..<haystack.endIndex
    }
        return count
    }

        var bestFull: String? = nil
        var bestScore = -1

        for (full, freq) in fullFreq {
        let parts = full.split(separator: " ").map { String($0) }
        let last = parts.last ?? full
        let lastKey = surnameKey(last)
        let fullKey = surnameKey(full)

        let occLast = countOccurrences(lastKey, in: allAlpha)
        let occFull = countOccurrences(fullKey, in: allAlpha)

        // Weighting: frequency dominates, then full-name hits (first+last letters-only), then surname hits
        let score = (freq * 1000) + (occFull * 300) + (occLast * 30) + full.count
        if score > bestScore {
            bestScore = score
            bestFull = full
    }
    }

        return bestFull
    }


    /// If OCR split the player's name across 2 consecutive lines (e.g., "GABE" then "PERREAULT"),
    /// rebuild it as "GABE PERREAULT". This is common on some scans where the baseline is cut.
    private static func cleanedLine(_ s: String) -> String {
        let upper = s.uppercased()
        // Keep only letters and spaces; turn punctuation/numbers into spaces to stabilize matching.
        let mapped = upper.map { ch -> Character in
        if ch.isLetter || ch == " " { return ch }
        return " "
    }
        let collapsed = String(mapped).replacingOccurrences(of: "\\s+", with: " ", options: String.CompareOptions.regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    static func findFullNameFromAdjacentLines(in raw: [String]) -> String? {
        let cleaned = raw.map { cleanedLine($0) }.filter { !$0.isEmpty }
        guard cleaned.count >= 2 else { return nil }

        let deny = Set([
        "YOUNG", "GUNS", "UPPER", "DECK", "SERIES", "HOCKEY", "AUTHENTIC", "ROOKIE", "RC",
        "HEIGHT", "WEIGHT", "SHOOTS", "BORN", "TEAM", "YEAR", "GP", "G", "A", "PTS", "PIM", "PPG", "+/-",
        "RW", "LW", "C", "D", "G"
        ])

        func isSingleNameWord(_ s: String) -> Bool {
        if s.count < 2 || s.count > 20 { return false }
        if deny.contains(s) { return false }
        if s.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil { return false }
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "-'"))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

        for i in 0..<(cleaned.count - 1) {
        let a = cleaned[i]
        let b = cleaned[i + 1]
        if a.contains(" ") || b.contains(" ") { continue }
        if !isSingleNameWord(a) || !isSingleNameWord(b) { continue }
        return "\(a) \(b)"
    }
        return nil
    }


private static func findLikelyLastName(in upperLines: [String]) -> String? {
        let stop = Set(["UPPER", "DECK", "YOUNG", "GUNS", "YOUNGG", "YOUNGC", "YOUNGGS", "SERIES", "ROOKIE", "RC", "NHL", "TEAM", "YEAR", "RANGERS", "NEW", "YORK", "CCM"])
        var best: String? = nil
        var bestScore = -1

        for l in upperLines {
        let parts = l
            .replacingOccurrences(of: "â€¢", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        for p in parts {
            guard p.count >= 6 else { continue }
            guard p.allSatisfy({ $0.isLetter }) else { continue }
            guard !stop.contains(p) else { continue }

            let score = p.count
            if score > bestScore {
                bestScore = score
                best = p
            }
    }
    }

        return best.map { FrontOCRParser.titleCasedName($0) }
    }

        private static func normalizeCardNumberCode(_ s: String) -> String {
        let up = s.uppercased()
        .replacingOccurrences(of: "â€“", with: "-")
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        let parts = up
        .replacingOccurrences(of: "â€¢", with: " ")
        .split(whereSeparator: { $0 == " " || $0 == "-" })
        .map { String($0) }
        .filter { !$0.isEmpty }

        guard parts.count >= 2 else { return up }
        let prefix = parts[0].filter { $0.isLetter }
        let digits = parts[1].filter { $0.isNumber }
        if prefix.isEmpty || digits.isEmpty { return up }
        return "\(prefix)-\(digits)"
    }

    private static func parseCardNumberInt(_ s: String?) -> Int? {
        guard let s else { return nil }
        let digits = s.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return Int(digits)
    }




    }
}

// MARK: String helpers


// MARK: String helpers (local)

// MARK: - Known players (optional bundle list)

fileprivate enum KnownPlayers {

    /// Cached canonical names (as written in the list file).
    private static let canonicalNames: [String] = {
        // If you add the generated file `all_players_1950_2025_unique.txt` to the app bundle,
        // we can use it here (one name per line).
        let candidates: [(String, String?)] = [
            ("all_players_1950_2025_unique", "txt"),
            ("all_players_1950_2025_unique", nil),
            ("all_players_1950_2025_unique", "text"),
            ("all_players_2008_2025_unique", "txt"),
            ("all_players_2008_2025_unique", nil)
        ]

        for (name, ext) in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                if let raw = try? String(contentsOf: url, encoding: .utf8) {
                    let lines = raw
                        .split(whereSeparator: \.isNewline)
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !lines.isEmpty { return lines }
                }
            }
        }
        return []
    }()

    /// Map normalized key -> canonical (for pretty output)
    private static let canonicalByKey: [String: String] = {
        var dict: [String: String] = [:]
        for n in canonicalNames {
            dict[normalizeNameForCompareStatic(n)] = n
        }
        return dict
    }()

    /// Index by last name to allow quick fuzzy match on first name.
    private static let byLastNameKey: [String: [String]] = {
        var dict: [String: [String]] = [:]
        for n in canonicalNames {
            let parts = n.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { continue }
            let last = normalizeTokenStatic(parts.last ?? "")
            dict[last, default: []].append(n)
        }
        return dict
    }()

    static func canonicalByNormalizedKey(_ key: String) -> String? {
        canonicalByKey[key]
    }
    
    /// Returns true if the known players list was successfully loaded from the bundle
    static func hasLoadedList() -> Bool {
        !canonicalNames.isEmpty
    }
    
    /// Searches all OCR lines to find the best matching player name from the known list.
    /// This is used as a fallback when the normal detection fails or returns invalid names.
    /// Returns the best matching canonical player name, or nil if no good match is found.
    static func findBestPlayerInLines(_ lines: [String]) -> String? {
        guard !canonicalNames.isEmpty else { return nil }
        guard !lines.isEmpty else { return nil }
        
        var bestMatch: (name: String, score: Int)? = nil
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 8, trimmed.count <= 40 else { continue } // reasonable name length
            
            // Try exact match first
            if let exact = canonicalize(trimmed) {
                // Score: 1000 - line length (prefer shorter, more focused lines)
                let score = 1000 - trimmed.count
                if bestMatch == nil || score > bestMatch!.score {
                    bestMatch = (exact, score)
                }
                continue
            }
            
            // Try fuzzy match on each word pair in the line
            let words = trimmed.split(separator: " ").map(String.init)
            if words.count >= 2 {
                // Try consecutive word pairs as potential "First Last" names
                for i in 0..<(words.count - 1) {
                    let candidate = "\(words[i]) \(words[i+1])"
                    if let match = canonicalize(candidate) {
                        let score = 900 - trimmed.count
                        if bestMatch == nil || score > bestMatch!.score {
                            bestMatch = (match, score)
                        }
                    }
                }
            }
        }
        
        return bestMatch?.name
    }

    /// Try to map a noisy OCR candidate to a canonical player name.
    /// - First tries exact normalized key match.
    /// - Then tries: same last name + first name edit distance <= 1 (handles small OCR typos).
    static func canonicalize(_ candidate: String) -> String? {
        guard !canonicalNames.isEmpty else { return nil }

        let key = normalizeNameForCompareStatic(candidate)
        if let exact = canonicalByKey[key] { return exact }

        let parts = candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map(String.init)

        guard parts.count >= 2 else { return nil }

        let first = normalizeTokenStatic(parts.first ?? "")
        let last  = normalizeTokenStatic(parts.last ?? "")

        guard !first.isEmpty, !last.isEmpty else { return nil }

        let pool = byLastNameKey[last] ?? []
        if pool.isEmpty { return nil }

        // Prefer the best edit distance on the first token.
        var best: (name: String, dist: Int)? = nil
        for name in pool {
            let canonicalParts = name.split(separator: " ").map(String.init)
            guard canonicalParts.count >= 2 else { continue }
            let canonicalFirst = normalizeTokenStatic(canonicalParts.first ?? "")
            let d = editDistanceAtMost2(first, canonicalFirst)
            if d <= 1 {
                if best == nil || d < best!.dist {
                    best = (name, d)
                    if d == 0 { break }
                }
            }
        }
        return best?.name
    }

    // MARK: - tiny helpers (static to avoid capture/self issues)

    private static func normalizeTokenStatic(_ s: String) -> String {
        s
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^A-Z ]", with: "", options: String.CompareOptions.regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private static func normalizeNameForCompareStatic(_ s: String) -> String {
        s
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^A-Z ]", with: "", options: String.CompareOptions.regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: String.CompareOptions.regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    /// Returns edit distance if <= 2, otherwise returns 3 (fast cutoff).
    private static func editDistanceAtMost2(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let la = a.count, lb = b.count
        if abs(la - lb) > 2 { return 3 }

        let aa = Array(a), bb = Array(b)
        var prev = Array(0...lb)
        var cur = Array(repeating: 0, count: lb + 1)

        for i in 1...la {
            cur[0] = i
            var bestInRow = cur[0]
            for j in 1...lb {
                let cost = (aa[i - 1] == bb[j - 1]) ? 0 : 1
                cur[j] = min(
                    prev[j] + 1,      // deletion
                    cur[j - 1] + 1,   // insertion
                    prev[j - 1] + cost // substitution
                )
                bestInRow = min(bestInRow, cur[j])
            }
            if bestInRow > 2 { return 3 }
            prev = cur
        }
        return prev[lb]
    }
}

// MARK: - Card Scan Camera Preview (UIKit wrapper)

private struct CardScanCameraPreview: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    
    func makeUIViewController(context: Context) -> CardScanCameraController {
        let vc = CardScanCameraController()
        vc.onCapture = onCapture
        return vc
    }
    
    func updateUIViewController(_ uiViewController: CardScanCameraController, context: Context) {}
}

private class CardScanCameraController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onCapture: ((UIImage) -> Void)?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var photoOutput: AVCapturePhotoOutput?
    
    // ✅ Ajout pour le zoom et macro
    private var currentDevice: AVCaptureDevice?
    private var currentZoomFactor: CGFloat = 1.0
    private let maxZoomFactor: CGFloat = 10.0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupCaptureButton()
        setupZoomGesture()  // ✅ Ajout
        setupZoomLabel()    // ✅ Ajout
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
    
    private func setupCamera() {
        captureSession = AVCaptureSession()
        captureSession?.sessionPreset = .photo
        
        // ✅ Essayer ultra-wide pour meilleurs close-ups, sinon wide-angle
        let backCamera: AVCaptureDevice?
        if let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            backCamera = ultraWide
            print("✅ Using ultra-wide camera")
        } else {
            backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            print("✅ Using wide-angle camera")
        }
        
        guard let device = backCamera,
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
        
        currentDevice = device  // ✅ Garder référence
        
        captureSession?.addInput(input)
        
        photoOutput = AVCapturePhotoOutput()
        if let photoOutput = photoOutput {
            captureSession?.addOutput(photoOutput)
        }
        
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession!)
        previewLayer?.videoGravity = .resizeAspectFill
        previewLayer?.frame = view.bounds
        view.layer.addSublayer(previewLayer!)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }
    
    private func setupCaptureButton() {
        // Outer ring
        let outerRing = UIView()
        outerRing.translatesAutoresizingMaskIntoConstraints = false
        outerRing.backgroundColor = .clear
        outerRing.layer.borderColor = UIColor.white.cgColor
        outerRing.layer.borderWidth = 4
        outerRing.layer.cornerRadius = 38
        outerRing.isUserInteractionEnabled = false
        
        // Inner circle
        let innerCircle = UIView()
        innerCircle.translatesAutoresizingMaskIntoConstraints = false
        innerCircle.backgroundColor = .white
        innerCircle.layer.cornerRadius = 30
        innerCircle.isUserInteractionEnabled = false
        
        // Button
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
        
        view.addSubview(outerRing)
        view.addSubview(innerCircle)
        view.addSubview(button)
        
        NSLayoutConstraint.activate([
            outerRing.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            outerRing.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            outerRing.widthAnchor.constraint(equalToConstant: 76),
            outerRing.heightAnchor.constraint(equalToConstant: 76),
            
            innerCircle.centerXAnchor.constraint(equalTo: outerRing.centerXAnchor),
            innerCircle.centerYAnchor.constraint(equalTo: outerRing.centerYAnchor),
            innerCircle.widthAnchor.constraint(equalToConstant: 60),
            innerCircle.heightAnchor.constraint(equalToConstant: 60),
            
            button.centerXAnchor.constraint(equalTo: outerRing.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: outerRing.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 76),
            button.heightAnchor.constraint(equalToConstant: 76)
        ])
    }
    
    // MARK: - Zoom Setup
    
    private func setupZoomGesture() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)
    }
    
    private func setupZoomLabel() {
        let label = UILabel()
        label.text = "Zoom: 1.0x"
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.textAlignment = .center
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.tag = 999  // Pour le retrouver plus tard
        view.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.widthAnchor.constraint(equalToConstant: 100),
            label.heightAnchor.constraint(equalToConstant: 32)
        ])
    }
    
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let device = currentDevice else { return }
        
        if gesture.state == .changed {
            let newZoom = currentZoomFactor * gesture.scale
            let maxZoom = min(maxZoomFactor, device.activeFormat.videoMaxZoomFactor)
            let clampedZoom = min(max(newZoom, 1.0), maxZoom)
            
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clampedZoom
                device.unlockForConfiguration()
                
                // Mettre à jour le label
                if let label = view.viewWithTag(999) as? UILabel {
                    label.text = String(format: "Zoom: %.1fx", clampedZoom)
                }
            } catch {
                print("⚠️ Zoom error: \(error)")
            }
        }
        
        if gesture.state == .ended {
            currentZoomFactor = device.videoZoomFactor
        }
    }
    
    @objc private func capturePhoto() {
        guard let photoOutput = photoOutput else { return }
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .auto
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.onCapture?(image)
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }
}

    // Force resize to exact dimensions
    private func resizeToFixedSize(_ image: UIImage, width: CGFloat, height: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

// MARK: - String Extensions

extension String {
    /// Capitalise la première lettre de chaque mot, le reste en minuscules
    /// Ex: "DUSTIN WOLF" → "Dustin Wolf"
    func properCapitalized() -> String {
        return self.lowercased()
            .split(separator: " ")
            .map { String($0.prefix(1).uppercased() + $0.dropFirst().lowercased()) }
            .joined(separator: " ")
    }
}
