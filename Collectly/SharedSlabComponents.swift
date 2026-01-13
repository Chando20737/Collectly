//
//  SharedSlabComponents.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-11.
//
import SwiftUI

// MARK: - Slab Image (réutilisable partout)

struct SlabThumb: View {
    let urlString: String?
    let dataImage: Data?   // pour Ma collection (local)
    let size: CGSize

    init(urlString: String? = nil, dataImage: Data? = nil, size: CGSize) {
        self.urlString = urlString
        self.dataImage = dataImage
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))

            if let dataImage, let uiImage = UIImage(data: dataImage) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                    case .failure:
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    default:
                        ProgressView()
                    }
                }
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 1)
        }
        .frame(width: size.width == 999 ? nil : size.width,
               height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

