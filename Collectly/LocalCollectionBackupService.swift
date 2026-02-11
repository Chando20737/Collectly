import Foundation
import SwiftData

/// Backup local (SwiftData) — protège les utilisateurs contre:
/// - réinstallation / changement d'appareil
/// - corruption de la base locale
/// - (cas extrême) changement de bundle identifier pendant le dev
///
/// ⚠️ Pour éviter des exports énormes, l'export peut exclure les images.
enum LocalCollectionBackupService {

    struct ExportCard: Codable {
        var id: UUID
        var createdAt: Date
        var ownerId: String

        var title: String
        var notes: String?

        var estimatedPriceCAD: Double?

        var playerName: String?
        var cardYear: String?
        var companyName: String?
        var setName: String?
        var cardNumber: String?

        var isGraded: Bool?
        var gradingCompany: String?
        var gradeValue: String?
        var certificationNumber: String?

        // Images (base64) — optionnel
        var frontImageBase64: String?
        var backImageBase64: String?
    }

    struct ExportPayload: Codable {
        var schemaVersion: Int = 1
        var exportedAt: Date = Date()
        var appName: String = "Cardia"
        var ownerId: String
        var cards: [ExportCard]
    }

    static func makeExportData(cards: [CardItem], ownerId: String, includeImages: Bool) throws -> Data {
        let exportCards: [ExportCard] = cards.map { card in
            ExportCard(
                id: card.id,
                createdAt: card.createdAt,
                ownerId: card.ownerId,
                title: card.title,
                notes: card.notes,
                estimatedPriceCAD: card.estimatedPriceCAD,
                playerName: card.playerName,
                cardYear: card.cardYear,
                companyName: card.companyName,
                setName: card.setName,
                cardNumber: card.cardNumber,
                isGraded: card.isGraded,
                gradingCompany: card.gradingCompany,
                gradeValue: card.gradeValue,
                certificationNumber: card.certificationNumber,
                frontImageBase64: includeImages ? card.frontImageData?.base64EncodedString() : nil,
                backImageBase64: includeImages ? card.backImageData?.base64EncodedString() : nil
            )
        }

        let payload = ExportPayload(ownerId: ownerId, cards: exportCards)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func decodeImportData(_ data: Data) throws -> ExportPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExportPayload.self, from: data)
    }

    /// Import dans SwiftData.
    /// - Si une carte avec le même `id` existe déjà, on la skip (évite doublons).
    /// - Les cartes importées seront forcées à `ownerId` (celui de l'utilisateur actuel).
    @MainActor
    static func importPayload(
        _ payload: ExportPayload,
        into modelContext: ModelContext,
        currentOwnerId: String,
        existingIds: Set<UUID>
    ) throws -> (imported: Int, skipped: Int) {

        var imported = 0
        var skipped = 0

        for c in payload.cards {
            if existingIds.contains(c.id) {
                skipped += 1
                continue
            }

            let item = CardItem(
                id: c.id,
                createdAt: c.createdAt,
                ownerId: currentOwnerId,
                title: c.title,
                notes: c.notes,
                frontImageData: c.frontImageBase64.flatMap { Data(base64Encoded: $0) },
                backImageData: c.backImageBase64.flatMap { Data(base64Encoded: $0) },
                estimatedPriceCAD: c.estimatedPriceCAD,
                playerName: c.playerName,
                cardYear: c.cardYear,
                companyName: c.companyName,
                setName: c.setName,
                cardNumber: c.cardNumber,
                isGraded: c.isGraded ?? false,  // ✅ Nil-coalescing pour rétrocompatibilité
                gradingCompany: c.gradingCompany,
                gradeValue: c.gradeValue,
                certificationNumber: c.certificationNumber
            )

            modelContext.insert(item)
            imported += 1
        }

        try modelContext.save()
        return (imported, skipped)
    }
}
