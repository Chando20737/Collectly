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

            ContentView()
                .tabItem {
                    Label("Ma collection", systemImage: "rectangle.stack")
                }

            MarketplaceCloudView()
                .tabItem {
                    Label("Marketplace", systemImage: "storefront")
                }

            MyListingsHubView()
                .tabItem {
                    Label("Mes annonces", systemImage: "tray.full")
                }
        }
    }
}
