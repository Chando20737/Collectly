//
//  NotificationRouter.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-13.
//
import Foundation
import Combine

@MainActor
final class NotificationRouter: ObservableObject {
    static let shared = NotificationRouter()

    /// Quand non-nil, l'app doit naviguer vers cette annonce.
    @Published var openListingId: String? = nil

    private init() {}

    func routeToListing(listingId: String) {
        openListingId = listingId
    }

    func clear() {
        openListingId = nil
    }
}

