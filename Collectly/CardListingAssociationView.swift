//
//  CardListingAssociationView.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-13.
//
import SwiftUI
import FirebaseAuth
import FirebaseFirestore

/// Affiche "Aucune annonce..." et, si possible, une annonce associée.
/// IMPORTANT: si Firestore retourne "permission denied", on l’ignore (UX propre).
struct CardListingAssociationView: View {

    let cardItemId: String

    @State private var isLoading = false
    @State private var listingId: String? = nil
    @State private var listingTitle: String? = nil
    @State private var listingStatus: String? = nil
    @State private var listingType: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Vérification de l’annonce…")
                        .foregroundStyle(.secondary)
                }
            } else if let listingId {
                VStack(alignment: .leading, spacing: 6) {
                    Text(listingTitle?.isEmpty == false ? listingTitle! : "Annonce")
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 8) {
                        badge(text: prettyType(listingType))
                        badge(text: prettyStatus(listingStatus))
                    }
                    .foregroundStyle(.secondary)

                    Text("ID: \(listingId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Aucune annonce associée à cette carte.")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await loadAssociation()
        }
    }

    // MARK: - Load

    @MainActor
    private func loadAssociation() async {
        // Si pas connecté, on n’essaie même pas (sinon Firestore peut dire permission denied)
        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty else {
            isLoading = false
            listingId = nil
            return
        }

        guard cardItemId.count == 36 else {
            isLoading = false
            listingId = nil
            return
        }

        isLoading = true
        listingId = nil
        listingTitle = nil
        listingStatus = nil
        listingType = nil

        do {
            // ✅ On cherche une annonce de CE user pour CETTE carte
            // (Aucune indexation spéciale requise pour 2 égalités + limit(1))
            let snap = try await Firestore.firestore()
                .collection("listings")
                .whereField("sellerId", isEqualTo: uid)
                .whereField("cardItemId", isEqualTo: cardItemId)
                .limit(to: 1)
                .getDocuments()

            guard let doc = snap.documents.first else {
                isLoading = false
                listingId = nil
                return
            }

            let data = doc.data()
            listingId = doc.documentID
            listingTitle = data["title"] as? String
            listingStatus = data["status"] as? String
            listingType = data["type"] as? String
            isLoading = false

        } catch {
            // ✅ Patch UX: si permission denied -> on cache le message (comme “pas d’annonce”)
            let ns = error as NSError
            if ns.domain == "FIRFirestoreErrorDomain", ns.code == 7 {
                isLoading = false
                listingId = nil
                return
            }

            // Autre erreur: on reste discret (ou tu peux logger)
            print("⚠️ CardListingAssociationView error:", error.localizedDescription)
            isLoading = false
            listingId = nil
        }
    }

    // MARK: - UI helpers

    private func badge(text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.secondary.opacity(0.12))
            .clipShape(Capsule())
    }

    private func prettyType(_ raw: String?) -> String {
        switch raw {
        case "auction": return "Encan"
        case "fixedPrice": return "Prix fixe"
        default: return "Annonce"
        }
    }

    private func prettyStatus(_ raw: String?) -> String {
        switch raw {
        case "active": return "Actif"
        case "paused": return "En pause"
        case "ended": return "Terminé"
        case "sold": return "Vendu"
        default: return raw ?? "—"
        }
    }
}

