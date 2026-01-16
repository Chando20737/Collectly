//
//  CardItem+Favorites.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-15.
//
import Foundation

/// ✅ Favoris (local) via UserDefaults
/// - On stocke les IDs de cartes favoris dans un Set<String>
/// - Clé unique: "favorites.cardItemIds"
///
/// Utilisation:
/// FavoritesStore.isFavorite(id: card.id)
/// FavoritesStore.toggle(id: card.id)
/// FavoritesStore.set(true/false, id: card.id)
/// FavoritesStore.clear(id: card.id)
enum FavoritesStore {

    private static let key = "favorites.cardItemIds"

    // MARK: - Public API

    static func isFavorite(id: UUID) -> Bool {
        let set = load()
        return set.contains(id.uuidString)
    }

    static func toggle(id: UUID) {
        var set = load()
        let s = id.uuidString
        if set.contains(s) { set.remove(s) } else { set.insert(s) }
        save(set)
    }

    static func set(_ isFav: Bool, id: UUID) {
        var set = load()
        let s = id.uuidString
        if isFav { set.insert(s) } else { set.remove(s) }
        save(set)
    }

    static func clear(id: UUID) {
        var set = load()
        set.remove(id.uuidString)
        save(set)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func allIds() -> Set<String> {
        load()
    }

    // MARK: - Persistence

    private static func load() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(arr)
    }

    private static func save(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: key)
    }
}

