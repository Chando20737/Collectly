import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LocalCollectionBackupView: View {

    let ownerId: String

    @Environment(\.modelContext) private var modelContext
    @Query private var cards: [CardItem]

    @State private var includeImages: Bool = false

    @State private var exportingDoc: BackupJSONDocument? = nil
    @State private var isExporting: Bool = false

    @State private var isImporting: Bool = false

    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var showAlert: Bool = false

    init(ownerId: String) {
        self.ownerId = ownerId
        _cards = Query(
            filter: #Predicate<CardItem> { $0.ownerId == ownerId },
            sort: [SortDescriptor(\CardItem.createdAt, order: .reverse)]
        )
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Cartes")
                    Spacer()
                    Text("\(cards.count)")
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $includeImages) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inclure les images")
                        Text("Recommandé OFF (fichier plus petit).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Backup local (SwiftData)")
            } footer: {
                Text("Ce backup protège contre les pertes lors d’une réinstallation, d’un nouvel appareil, ou d’un crash de la base locale.")
            }

            Section {
                Button {
                    exportNow()
                } label: {
                    Label("Exporter en JSON", systemImage: "tray.and.arrow.up")
                }
                .disabled(isExporting)

                Button {
                    isImporting = true
                } label: {
                    Label("Importer un JSON", systemImage: "tray.and.arrow.down")
                }
                .disabled(isImporting)
            }

            Section {
                Text("Astuce: fais un export avant de tester de grosses modifs (OCR, eBay, migrations).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Backup")
        .fileExporter(
            isPresented: $isExporting,
            document: exportingDoc,
            contentType: .json,
            defaultFilename: defaultFilename
        ) { result in
            switch result {
            case .success:
                showOK("Export réussi", "Le fichier JSON a été exporté.")
            case .failure(let error):
                showOK("Export échoué", error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                importFrom(url: url)
            case .failure(let error):
                showOK("Import échoué", error.localizedDescription)
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }

    private var defaultFilename: String {
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "cardia-backup-\(ownerId.prefix(8))-\(date)"
    }

    private func exportNow() {
        do {
            let data = try LocalCollectionBackupService.makeExportData(
                cards: cards,
                ownerId: ownerId,
                includeImages: includeImages
            )
            exportingDoc = BackupJSONDocument(data: data)
            isExporting = true
        } catch {
            showOK("Export échoué", error.localizedDescription)
        }
    }

    private func importFrom(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let payload = try LocalCollectionBackupService.decodeImportData(data)

            // Existing IDs (pour éviter doublons)
            let existingIds = Set(cards.map { $0.id })

            Task { @MainActor in
                do {
                    let result = try LocalCollectionBackupService.importPayload(
                        payload,
                        into: modelContext,
                        currentOwnerId: ownerId,
                        existingIds: existingIds
                    )
                    showOK("Import terminé", "Importées: \(result.imported)\nIgnorées: \(result.skipped)")
                } catch {
                    showOK("Import échoué", error.localizedDescription)
                }
            }
        } catch {
            showOK("Import échoué", error.localizedDescription)
        }
    }

    private func showOK(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
        isExporting = false
        isImporting = false
    }
}

struct BackupJSONDocument: FileDocument {

    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
