//
//  CardItem+Grading.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-15.
//
import Foundation

extension CardItem {
    /// Libellé de grading lisible partout (Grid, List, QuickEdit, Detail)
    var gradingLabel: String? {
        let g = (gradeValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let c = (gradingCompany ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { return nil }
        return c.isEmpty ? g : "\(c) \(g)"
    }
}

