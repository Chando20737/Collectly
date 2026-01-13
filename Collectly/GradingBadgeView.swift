//
//  GradingBadgeView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-12.
//
import SwiftUI

/// Badge type "PSA 10" / "BGS 9.5" / etc.
struct GradingBadgePill: View {
    let gradingCompany: String?
    let gradeValue: String?
    let forceShow: Bool   // si true, montre même si pas gradée (rarement utile)

    init(gradingCompany: String?, gradeValue: String?, forceShow: Bool = false) {
        self.gradingCompany = gradingCompany
        self.gradeValue = gradeValue
        self.forceShow = forceShow
    }

    var body: some View {
        if let label = labelText {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                Text(label)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.blue)
            )
        } else {
            EmptyView()
        }
    }

    private var labelText: String? {
        let c = gradingCompany?.trimmedLocal
        let g = gradeValue?.trimmedLocal

        // On veut au minimum une note (10 / 9.5 / etc.)
        guard forceShow || (g?.isEmpty == false) else { return nil }

        if let c, !c.isEmpty, let g, !g.isEmpty { return "\(c) \(g)" }
        if let g, !g.isEmpty { return g }
        return nil
    }
}

struct GradingBadgeMini: View {
    let gradingCompany: String?
    let gradeValue: String?

    var body: some View {
        if let label = labelText {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal.fill")
                Text(label)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.blue.opacity(0.25), lineWidth: 1)
            )
        } else {
            EmptyView()
        }
    }

    private var labelText: String? {
        let c = gradingCompany?.trimmedLocal
        let g = gradeValue?.trimmedLocal
        guard let g, !g.isEmpty else { return nil }
        if let c, !c.isEmpty { return "\(c) \(g)" }
        return g
    }
}

// MARK: - Helpers

private extension String {
    var trimmedLocal: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

