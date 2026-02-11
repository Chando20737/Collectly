//
//  Listing.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import Foundation
import SwiftData

enum ListingStatus: String, Codable {
    case active
    case sold
    case ended
}

@Model
final class Listing {
    var id: UUID
    var createdAt: Date

    // Lien vers ta carte
    var card: CardItem?

    // Marketplace
    var typeRaw: String
    var statusRaw: String

    var title: String
    var descriptionText: String?

    // Prix fixe
    var buyNowPriceCAD: Double?

    // Encan
    var startingBidCAD: Double?
    var endDate: Date?
    var currentBidCAD: Double?
    var bidCount: Int

    init(card: CardItem,
         type: ListingType,
         title: String,
         descriptionText: String? = nil,
         buyNowPriceCAD: Double? = nil,
         startingBidCAD: Double? = nil,
         endDate: Date? = nil)
    {
        self.id = UUID()
        self.createdAt = Date()

        self.card = card
        self.typeRaw = type.rawValue
        self.statusRaw = ListingStatus.active.rawValue

        self.title = title
        self.descriptionText = descriptionText

        self.buyNowPriceCAD = buyNowPriceCAD

        self.startingBidCAD = startingBidCAD
        self.endDate = endDate
        self.currentBidCAD = startingBidCAD
        self.bidCount = 0
    }

    var type: ListingType { ListingType(rawValue: typeRaw) ?? .fixedPrice }
    var status: ListingStatus { ListingStatus(rawValue: statusRaw) ?? .active }

    func markSold() {
        statusRaw = ListingStatus.sold.rawValue
    }

    func endAuction() {
        statusRaw = ListingStatus.ended.rawValue
    }
}

