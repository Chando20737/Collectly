//
//  UserProfile.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-11.
//
import Foundation
import FirebaseFirestore

struct UserProfile: Identifiable, Equatable {
    let id: String   // uid

    var username: String
    var createdAt: Timestamp

    static func fromFirestore(doc: DocumentSnapshot) -> UserProfile? {
        guard let data = doc.data() else { return nil }
        return UserProfile(
            id: doc.documentID,
            username: data["username"] as? String ?? "",
            createdAt: data["createdAt"] as? Timestamp ?? Timestamp(date: Date())
        )
    }

    func toFirestore() -> [String: Any] {
        [
            "username": username,
            "createdAt": createdAt
        ]
    }
}

