//
//  MyListingsHubView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-14.
//
import SwiftUI
import FirebaseAuth   // ✅ OBLIGATOIRE pour accéder à user.uid

struct MyListingsHubView: View {

    @EnvironmentObject private var session: SessionStore

    var body: some View {
        NavigationStack {
            Group {
                if session.user == nil {
                    ContentUnavailableView(
                        "Mes annonces",
                        systemImage: "tray.full",
                        description: Text("Connecte-toi pour gérer tes ventes et tes enchères.")
                    )
                } else {
                    List {
                        Section("Mon activité") {

                            NavigationLink {
                                MyDealsCloudView(
                                    userId: session.user!.uid,
                                    initialTab: .sales
                                )
                            } label: {
                                Label("Mes ventes", systemImage: "tag.fill")
                            }

                            NavigationLink {
                                MyDealsCloudView(
                                    userId: session.user!.uid,
                                    initialTab: .bids
                                )
                            } label: {
                                Label("Mes enchères", systemImage: "hammer.fill")
                            }
                        }

                        Section {
                            NavigationLink {
                                MarketplaceCloudView()
                            } label: {
                                Label("Aller au Marketplace", systemImage: "storefront")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Mes annonces")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
