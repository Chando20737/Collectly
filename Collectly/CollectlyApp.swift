//
//  CollectlyApp.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import SwiftData
import FirebaseCore

@main
struct CollectlyApp: App {

    // ✅ UNE seule instance globale (injectée partout)
    @StateObject private var session = SessionStore()

    // ✅ SwiftData container (persistant) - avec fallback si migration échoue
    private var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            CardItem.self,
            Listing.self
        ])

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        // 1) Tentative normale
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // 2) Si migration échoue, on supprime le store et on retente
            print("⚠️ SwiftData container load failed. Attempting reset. Error: \(error)")

            Self.deleteDefaultSwiftDataStoreFiles()

            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("❌ Could not create ModelContainer even after reset: \(error)")
            }
        }
    }()

    init() {
        // ✅ Firebase doit être configuré UNE seule fois au démarrage
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }

        // (Optionnel) Debug rapide
        // print("✅ Firebase configured. Apps: \(FirebaseApp.allApps?.keys ?? [])")
    }

    var body: some Scene {
        WindowGroup {
            AppEntryView()
                .environmentObject(session) // ✅ injecte partout
        }
        .modelContainer(sharedModelContainer)
    }
}

// MARK: - Reset store helper (si migration impossible)

private extension CollectlyApp {

    static func deleteDefaultSwiftDataStoreFiles() {
        let fm = FileManager.default

        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            print("⚠️ Could not locate Application Support directory.")
            return
        }

        // SwiftData utilise généralement "default.store"
        let storeURL = appSupport.appendingPathComponent("default.store")

        // Parfois il peut y avoir des fichiers associés (journaux, shm/wal, etc.)
        // On supprime tout ce qui commence par "default.store"
        do {
            let contents = try fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil)

            let toDelete = contents.filter { url in
                url.lastPathComponent.hasPrefix("default.store")
                || url.lastPathComponent == "default.store"
            }

            if toDelete.isEmpty {
                // fallback: supprimer exactement default.store si présent
                if fm.fileExists(atPath: storeURL.path) {
                    try fm.removeItem(at: storeURL)
                    print("✅ Deleted \(storeURL.lastPathComponent)")
                } else {
                    print("ℹ️ No SwiftData default.store found to delete.")
                }
                return
            }

            for url in toDelete {
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                    print("✅ Deleted \(url.lastPathComponent)")
                }
            }

        } catch {
            print("⚠️ Failed to delete SwiftData store files: \(error)")
        }
    }
}
