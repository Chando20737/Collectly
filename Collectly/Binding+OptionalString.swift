//
//  Binding+OptionalString.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI

extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith nilReplacement: String) {
        self.init(
            get: { source.wrappedValue ?? nilReplacement },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                source.wrappedValue = trimmed.isEmpty ? nil : trimmed
            }
        )
    }
}
