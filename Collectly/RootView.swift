//
//  RootView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-11.
//
import SwiftUI

struct RootView: View {

    @EnvironmentObject private var session: SessionStore

    var body: some View {
        TabView {

            // ✅ Ma collection (clean)
            ContentView()
                .tabItem {
                    Label("Ma collection", systemImage: "rectangle.stack")
                }

            // ✅ Marketplace
            MarketplaceView()
                .tabItem {
                    Label("Marketplace", systemImage: "cart")
                }

            // ✅ Mes annonces (hub: Mes ventes / Mes enchères)
            MyListingsHubView()
                .tabItem {
                    Label("Mes annonces", systemImage: "tray.full")
                }
        }
    }
}
