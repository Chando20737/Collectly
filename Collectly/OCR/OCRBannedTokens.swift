import Foundation

enum OCRBannedTokenCategory: String, CaseIterable {
    case manufacturerBrand
    case leagueProgramMarks
    case setInsertSubset
    case certificationBackText
    case teamCityMascot
    case attributesParallel
    case commonJunk
}

struct OCRBannedTokens {

    static let byCategory: [OCRBannedTokenCategory: Set<String>] = [

        .manufacturerBrand: [
            "UPPER", "DECK", "UPPERDECK",
            "PANINI", "TOPPS", "LEAF", "ITG"
        ],

        .leagueProgramMarks: [
            "NHL", "NHLPA", "AHL", "CHL", "UDC"
        ],

        .setInsertSubset: [
            "AUTHENTIC", "ROOKIE", "ROOKIES",
            "YOUNG", "GUNS",
            "FUTURE", "WATCH",
            "SIGNATURE", "AUTO", "AUTOGRAPH",
            "PATCH", "JERSEY", "MEMORABILIA",
            "EDITION", "LIMITED"
        ],

        .certificationBackText: [
            "CONGRATULATIONS",
            "CERTIFIED",
            "AUTHENTICITY",
            "REPRESENTATIVE",
            "COMPANY",
            "ENJOY",
            "SIGNED",
            "PRESENCE",
            "PROVIDED"
        ],

        .teamCityMascot: [
            "BLACKHAWKS", "CANADIENS", "MONTREAL",
            "TORONTO", "MAPLE", "LEAFS",
            "RANGERS", "BRUINS", "OILERS"
        ],

        .attributesParallel: [
            "BLUE", "RED", "GREEN", "GOLD", "SILVER", "PLATINUM",
            "RAINBOW", "HOLO", "PRIZM", "NUMBERED"
        ],

        .commonJunk: [
            "C", "RC", "R", "#"
        ]
    ]

    static var all: Set<String> {
        byCategory.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    static func active(_ categories: Set<OCRBannedTokenCategory>) -> Set<String> {
        categories.reduce(into: Set<String>()) { partial, cat in
            partial.formUnion(byCategory[cat] ?? [])
        }
    }
}
