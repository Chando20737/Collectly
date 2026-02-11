//
//  ListingThumb.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-10.
//
import SwiftUI

struct ListingThumb: View {
    let urlString: String?

    var body: some View {
        Group {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        ZStack {
                            Rectangle().fill(.gray.opacity(0.2))
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    default:
                        ZStack {
                            Rectangle().fill(.gray.opacity(0.15))
                            ProgressView()
                        }
                    }
                }
            } else {
                ZStack {
                    Rectangle().fill(.gray.opacity(0.2))
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

