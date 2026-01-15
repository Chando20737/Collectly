//
//  RootView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-11.
//
import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {

            // 1) Ma collection
            ContentView()
                .tabItem {
                    Label("Ma collection", systemImage: "rectangle.stack")
                }

            // 2) Marketplace
            MarketplaceCloudView()
                .tabItem {
                    Label("Marketplace", systemImage: "storefront")
                }

            // 3) Mes annonces (hub)
            MyListingsHubView()
                .tabItem {
                    Label("Mes annonces", systemImage: "tray.full")
                }
        }
    }
}
