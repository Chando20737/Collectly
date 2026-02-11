//
//  Item.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
