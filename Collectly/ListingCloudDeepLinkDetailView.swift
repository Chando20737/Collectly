//
//  ListingCloudDeepLinkDetailView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-13.
//
import SwiftUI
import FirebaseFirestore

struct ListingCloudDeepLinkDetailView: View {

    let listingId: String

    @Environment(\.dismiss) private var dismiss

    @State private var listing: ListingCloud?
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Chargement de l’annonce…")
            } else if let errorText {
                ContentUnavailableView(
                    "Annonce introuvable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorText)
                )
            } else if let listing {
                ListingCloudDetailView(listing: listing)
            } else {
                ContentUnavailableView(
                    "Annonce introuvable",
                    systemImage: "xmark.circle",
                    description: Text("Aucune donnée reçue.")
                )
            }
        }
        .navigationTitle("Annonce")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Fermer") { dismiss() }
            }
        }
        .onAppear { fetch() }
    }

    private func fetch() {
        isLoading = true
        errorText = nil

        let ref = Firestore.firestore().collection("listings").document(listingId)
        ref.getDocument { snap, error in
            if let error {
                isLoading = false
                errorText = error.localizedDescription
                return
            }

            guard let snap, snap.exists else {
                isLoading = false
                errorText = "Cette annonce n’existe plus (ou n’est pas accessible)."
                return
            }

            listing = ListingCloud.fromFirestore(doc: snap)
            isLoading = false
        }
    }
}


