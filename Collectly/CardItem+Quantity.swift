//
//  CardItem+Quantity.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-15.
//
import Foundation

/// ✅ Quantité (doubles) persistée en UserDefaults
/// - Clé: "quantity.cardItemById"
/// - Stocke un dictionnaire ["<uuid>": Int]
/// - Valeur min: 1
/// - Valeur max: 999 (modifiable)
enum QuantityStore {

    private static let key = "quantity.cardItemById"
    private static let minQty = 1
    private static let maxQty = 999

    // MARK: - Public API

    static func quantity(id: UUID) -> Int {
        let dict = load()
        let raw = dict[id.uuidString] ?? minQty
        return clamp(raw)
    }

    static func setQuantity(_ qty: Int, id: UUID) {
        var dict = load()
        dict[id.uuidString] = clamp(qty)
        save(dict)
    }

    static func increment(id: UUID, by delta: Int = 1) {
        let current = quantity(id: id)
        setQuantity(current + delta, id: id)
    }

    static func decrement(id: UUID, by delta: Int = 1) {
        let current = quantity(id: id)
        setQuantity(current - delta, id: id)
    }

    static func clear(id: UUID) {
        var dict = load()
        dict.removeValue(forKey: id.uuidString)
        save(dict)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Persistence

    private static func load() -> [String: Int] {
        if let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] {
            return dict
        }
        return [:]
    }

    private static func save(_ dict: [String: Int]) {
        UserDefaults.standard.set(dict, forKey: key)
    }

    private static func clamp(_ v: Int) -> Int {
        min(max(v, minQty), maxQty)
    }
}

