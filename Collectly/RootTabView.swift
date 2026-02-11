//
//  RootTabView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import FirebaseFirestore

struct RootTabView: View {

    @EnvironmentObject private var router: DeepLinkRouter

    // ✅ Pour sélectionner l’onglet automatiquement
    @State private var selectedTab: Tab = .marketplace

    // ✅ Pour ouvrir la fiche annonce
    @State private var presentedListingId: PresentedListingId?

    enum Tab: Hashable {
        case collection
        case marketplace
        case myListings
        case profile
    }

    var body: some View {
        TabView(selection: $selectedTab) {

            // ✅ Ma collection (local SwiftData)
            ContentView()
                .tabItem { Label("Ma collection", systemImage: "rectangle.stack") }
                .tag(Tab.collection)

            // ✅ Marketplace (public)
            MarketplaceCloudView()
                .tabItem { Label("Marketplace", systemImage: "tag") }
                .tag(Tab.marketplace)

            // ✅ Mes annonces (si pas connecté, la vue montre "Connexion requise")
            MyListingsHubView()
                .tabItem { Label("Mes annonces", systemImage: "tray.full") }
                .tag(Tab.myListings)

            // ✅ Profil
            ProfileView()
                .tabItem { Label("Profil", systemImage: "person.crop.circle") }
                .tag(Tab.profile)
        }
        // ✅ Quand une notification est tapée -> router.openListingId change -> on ouvre
        .onChange(of: router.openListingId) { _, newValue in
            guard let id = newValue, !id.isEmpty else { return }

            Task { @MainActor in
                // 1) On va sur Marketplace
                selectedTab = .marketplace

                // 2) On ouvre (ou remplace) la fiche annonce
                presentedListingId = PresentedListingId(id: id)

                // 3) On “consomme” le deep link
                router.clear()
            }
        }
        // ✅ Présentation de la page annonce (sheet)
        .sheet(item: $presentedListingId) { item in
            NavigationStack {
                ListingByIdView(listingId: item.id)
            }
        }
    }
}

// MARK: - Identifiable wrapper pour .sheet(item:)

private struct PresentedListingId: Identifiable, Equatable {
    let id: String
}

// MARK: - Loader Firestore: /listings/{listingId} -> ListingCloudDetailView

private struct ListingByIdView: View {
    let listingId: String

    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var listing: ListingCloud?
    @State private var errorText: String?

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Ouverture de l’annonce…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if let errorText {
                ContentUnavailableView(
                    "Impossible d’ouvrir l’annonce",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorText)
                )

            } else if let listing {
                ListingCloudDetailView(listing: listing)

            } else {
                ContentUnavailableView(
                    "Annonce introuvable",
                    systemImage: "questionmark.folder",
                    description: Text("Cette annonce n’existe plus ou n’est plus accessible.")
                )
            }
        }
        .navigationTitle("Annonce")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Fermer") { dismiss() }
            }
        }
        .task {
            await loadListing()
        }
    }

    @MainActor
    private func loadListing() async {
        isLoading = true
        errorText = nil
        listing = nil

        do {
            let doc = try await Firestore.firestore()
                .collection("listings")
                .document(listingId)
                .getDocument()

            guard doc.exists else {
                isLoading = false
                listing = nil
                return
            }

            listing = ListingCloud.fromFirestore(doc: doc)
            isLoading = false

        } catch {
            errorText = error.localizedDescription
            isLoading = false
        }
    }
}

