//
//  CollectlyApp.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseAppCheck

@main
struct CollectlyApp: App {

    // ✅ On garde AppDelegate pour Push (APNs/FCM delegates)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var session: SessionStore
    @StateObject private var router: DeepLinkRouter

    // ✅ Pour éviter d'exécuter 2x le setup push si onAppear est rappelé
    @State private var didSetupPush = false

    private var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            CardItem.self,
            Listing.self
        ])

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            print("⚠️ SwiftData container load failed. Attempting reset. Error: \(error)")
            Self.deleteDefaultSwiftDataStoreFiles()

            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer even after reset: \(error)")
            }
        }
    }()

    init() {
        // ✅ App Check factory AVANT FirebaseApp.configure()
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        print("🟢 APP CHECK = DEBUG provider (CollectlyApp.init)")
        #else
        AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
        print("🔴 APP CHECK = ATTEST provider (CollectlyApp.init)")
        #endif

        // ✅ Firebase le plus tôt possible
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
            print("✅ Firebase configured (CollectlyApp.init)")
        }

        // ✅ Ensuite seulement, on instancie tes StateObject
        _session = StateObject(wrappedValue: SessionStore())
        _router  = StateObject(wrappedValue: DeepLinkRouter())
    }

    var body: some Scene {
        WindowGroup {
            AppEntryView()
                .environmentObject(session)
                .environmentObject(router)
                .onAppear {
                    guard !didSetupPush else { return }
                    didSetupPush = true

                    PushNotificationsManager.shared.attachRouter(router)
                    PushNotificationsManager.shared.requestAuthorizationAndRegister()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

private extension CollectlyApp {

    static func deleteDefaultSwiftDataStoreFiles() {
        let fm = FileManager.default

        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            print("⚠️ Could not locate Application Support directory.")
            return
        }

        do {
            let contents = try fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil)

            let toDelete = contents.filter { url in
                url.lastPathComponent.hasPrefix("default.store")
                || url.lastPathComponent == "default.store"
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
