//
//  RootTabView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI
import FirebaseAuth

struct RootTabView: View {

    var body: some View {
        TabView {
            // ✅ Ma collection (local SwiftData)
            ContentView()
                .tabItem {
                    Label("Ma collection", systemImage: "rectangle.stack")
                }

            // ✅ Marketplace (public)
            MarketplaceCloudView()
                .tabItem {
                    Label("Marketplace", systemImage: "tag")
                }

            // ✅ Mes annonces (seulement si connecté)
            MyListingsView()
                .tabItem {
                    Label("Mes annonces", systemImage: "tray.full")
                }

            // ✅ Profil
            ProfileView()
                .tabItem {
                    Label("Profil", systemImage: "person.crop.circle")
                }
        }
    }
}
