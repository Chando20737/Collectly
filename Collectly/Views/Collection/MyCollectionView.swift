//
//  MyCollectionView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-16.
//
import SwiftUI
import SwiftData

struct MyCollectionView: View {

    let uid: String

    @Environment(\.modelContext) private var modelContext
    @Query private var cards: [CardItem]

    init(uid: String) {
        self.uid = uid
        _cards = Query(
            filter: #Predicate<CardItem> { $0.ownerId == uid },
            sort: [SortDescriptor(\CardItem.createdAt, order: .reverse)]
        )
    }

    var body: some View {
        List {
            if cards.isEmpty {
                ContentUnavailableView(
                    "Aucune carte",
                    systemImage: "rectangle.stack",
                    description: Text("Ajoute ta première carte.")
                )
            } else {
                ForEach(cards) { c in
                    Text(c.title)
                }
            }
        }
        .navigationTitle("Ma collection")
    }
}

