//
//  PushNotificationsManager.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-13.
//
import Foundation
import FirebaseMessaging
import FirebaseAuth
import FirebaseFirestore
import UserNotifications
import UIKit

final class PushNotificationsManager: NSObject {

    static let shared = PushNotificationsManager()

    private override init() {
        super.init()
    }

    // MARK: - Public

    /// À appeler au démarrage de l'app (après FirebaseApp.configure()).
    func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self

        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, error in
            if let error {
                print("❌ Push permission error:", error.localizedDescription)
            } else {
                print("🔔 Push permission granted:", granted)
            }
        }

        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Appelé par AppDelegate quand Firebase donne/rafraîchit le token FCM.
    func handleNewFCMToken(_ token: String) {
        print("📲 FCM token:", token)
        saveTokenToFirestore(token)
    }

    // MARK: - Save token

    private func saveTokenToFirestore(_ token: String) {
        guard let uid = Auth.auth().currentUser?.uid else {
            print("⚠️ Not signed in; cannot save FCM token.")
            return
        }

        let data: [String: Any] = [
            "fcmToken": token,
            "platform": "ios",
            "updatedAt": Timestamp(date: Date())
        ]

        Firestore.firestore()
            .collection("users")
            .document(uid)
            .setData(data, merge: true)

        print("✅ FCM token saved in /users/\(uid)")
    }
}

// MARK: - MessagingDelegate

extension PushNotificationsManager: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken, !token.isEmpty else {
            print("⚠️ FCM token is nil/empty")
            return
        }
        handleNewFCMToken(token)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotificationsManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound, .badge]
    }
}
