//
//  PushNotificationsManager.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-13.
//
import Foundation
import FirebaseAuth
import FirebaseFirestore
import UserNotifications
import UIKit

@MainActor
final class PushNotificationsManager: NSObject {

    static let shared = PushNotificationsManager()

    // weak pour éviter un cycle mémoire (router est un EnvironmentObject)
    private weak var router: DeepLinkRouter?

    private override init() {
        super.init()
    }

    // MARK: - Router

    /// Injecté dès que ton router existe (CollectlyApp.onAppear)
    func attachRouter(_ router: DeepLinkRouter) {
        self.router = router
        print("✅ PushNotificationsManager: router attached")
    }

    // MARK: - Permission + Register

    /// Demande la permission et enregistre auprès d'APNs.
    /// Le token APNs arrive dans AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken
    func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, error in
            if let error {
                print("❌ Notification permission error:", error.localizedDescription)
            } else {
                print("🔔 Push permission granted:", granted)
            }
        }

        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    // MARK: - Token FCM -> Firestore

    /// Appelé depuis AppDelegate.messaging(_:didReceiveRegistrationToken:)
    func handleNewFCMToken(_ token: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            print("⚠️ PushNotificationsManager: received empty FCM token")
            return
        }

        // Firestore peut prendre un peu de temps → on évite de bloquer le MainActor
        Task {
            await saveTokenToFirestore(t)
        }
    }

    private func saveTokenToFirestore(_ token: String) async {
        guard let uid = Auth.auth().currentUser?.uid else {
            print("ℹ️ FCM token received but user is not signed in yet (not saving).")
            return
        }

        let data: [String: Any] = [
            "fcmToken": token,
            "platform": "ios",
            "updatedAt": Timestamp(date: Date())
        ]

        do {
            try await Firestore.firestore()
                .collection("users")
                .document(uid)
                .setData(data, merge: true)

            print("✅ FCM token saved in /users/\(uid)")
        } catch {
            print("❌ Failed to save FCM token in /users/\(uid):", error.localizedDescription)
        }
    }

    // MARK: - Tap on Notification -> Deep link

    /// Appelé depuis AppDelegate.userNotificationCenter(_:didReceive:)
    func handleNotificationTap(_ userInfo: [AnyHashable: Any]) {
        print("📩 PushNotificationsManager.handleNotificationTap userInfo =", userInfo)

        guard let router else {
            print("⚠️ PushNotificationsManager: router is nil (attachRouter not called yet)")
            return
        }

        router.handleNotificationUserInfo(userInfo)
    }
}
