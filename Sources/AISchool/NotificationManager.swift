import Foundation
import UserNotifications
import StudyCore

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var status: UNAuthorizationStatus = .notDetermined
    @Published var pendingCount = 0
    var onOpenLink: ((URL) -> Void)?

    /// UserNotifications only works for a real .app bundle (not `swift run`).
    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    override init() {
        super.init()
        if isAvailable { UNUserNotificationCenter.current().delegate = self }
    }

    func refreshStatus() async {
        guard isAvailable else { return }
        let s = await UNUserNotificationCenter.current().notificationSettings()
        status = s.authorizationStatus
        pendingCount = await UNUserNotificationCenter.current().pendingNotificationRequests().count
    }

    func requestPermission() async {
        guard isAvailable else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshStatus()
    }

    /// Replaces every pending study notification with the freshly planned set. Delivery is handled by macOS,
    /// so these fire even when the app window is closed (as long as the plan was scheduled recently).
    func reschedule(_ plan: [PlannedNotification]) async {
        guard isAvailable, status == .authorized || status == .provisional else { await refreshStatus(); return }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let cal = Calendar.current
        for n in plan.prefix(60) {   // macOS keeps at most 64 pending requests per app
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = n.body
            if n.category == .assessment { content.sound = UNNotificationSound.default }
            content.userInfo = ["link": n.link]
            content.threadIdentifier = "study"
            if n.category == .quiz || n.category == .evening { content.interruptionLevel = .passive }
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: n.fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: n.id, content: content, trigger: trigger))
        }
        await refreshStatus()
    }

    func sendTest() async {
        guard isAvailable else { return }
        let c = UNMutableNotificationContent()
        c.title = "Notifications are working"
        c.body = "Tap to open your home screen."
        c.userInfo = ["link": "aischool://home"]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: c,
                                                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let link = response.notification.request.content.userInfo["link"] as? String
        Task { @MainActor in
            if let l = link, let url = URL(string: l) { self.onOpenLink?(url) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
