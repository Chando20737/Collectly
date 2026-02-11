//
//  CollectionSelectionToolbar.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-15.
//
import SwiftUI

struct CollectionSelectionToolbar: View {

    let selectedCount: Int

    let onMerge: () -> Void

    let onIncrementQty: () -> Void
    let onDecrementQty: () -> Void

    let onFavorite: () -> Void
    let onUnfavorite: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 16) {

                Text("\(selectedCount) sélectionnée\(selectedCount > 1 ? "s" : "")")
                    .font(.footnote.weight(.semibold))

                Spacer()

                Button { onDecrementQty() } label: {
                    Image(systemName: "minus.circle")
                }
                .accessibilityLabel("Diminuer la quantité")

                Button { onIncrementQty() } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Augmenter la quantité")

                Divider()
                    .frame(height: 18)

                Button { onMerge() } label: {
                    Image(systemName: "arrow.triangle.merge")
                }
                .accessibilityLabel("Fusionner")

                Button { onFavorite() } label: {
                    Image(systemName: "star.fill")
                }
                .accessibilityLabel("Ajouter aux favoris")

                Button { onUnfavorite() } label: {
                    Image(systemName: "star.slash.fill")
                }
                .accessibilityLabel("Retirer des favoris")

                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Supprimer")

                Button("Annuler") { onCancel() }
                    .accessibilityLabel("Annuler la sélection")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }
}
