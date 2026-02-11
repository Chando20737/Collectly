//
//  CollectionQuantityStore.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-16.
//
import Foundation

/// ✅ Alias/wrapper pour compatibilité avec le code de ContentView
/// Ton projet a déjà `QuantityStore` (CardItem+Quantity).
/// On expose ici la même API que ContentView attend: CollectionQuantityStore.*
enum CollectionQuantityStore {

    static func quantity(id: UUID) -> Int {
        QuantityStore.quantity(id: id)
    }

    static func setQuantity(_ quantity: Int, id: UUID) {
        QuantityStore.setQuantity(quantity, id: id)
    }

    static func increment(id: UUID, by delta: Int = 1) {
        QuantityStore.increment(id: id, by: delta)
    }

    static func decrement(id: UUID, by delta: Int = 1) {
        QuantityStore.decrement(id: id, by: delta)
    }

    static func clear(id: UUID) {
        QuantityStore.clear(id: id)
    }

    static func clearAll() {
        QuantityStore.clearAll()
    }
}
