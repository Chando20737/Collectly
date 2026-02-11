//
//  CardItem+Grading.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-15.
//
import Foundation

extension CardItem {

    /// ✅ Libellé de grading lisible partout (Grid, List, Quick Edit, Detail)
    /// Exemple: "PSA 10" ou "10" si la compagnie est vide.
    var gradingLabel: String? {
        let grade = (gradeValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let company = (gradingCompany ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !grade.isEmpty else { return nil }
        return company.isEmpty ? grade : "\(company) \(grade)"
    }
}

