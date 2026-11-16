import AppKit
import UserNotifications

/// Posts one summary notification per finished batch. Clicking a success opens
/// the document (or the document list); a failure offers Retry, and clicking one
/// caused by URL or token opens Settings.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private static let failedCategory = "uploadFailed"
    private static let retryAction = "retry"

    var onRetry: ([URL]) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let retry = UNNotificationAction(identifier: Self.retryAction, title: "Retry", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.failedCategory, actions: [retry], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { log.error("Notification permission: \(error.localizedDescription, privacy: .public)") }
            log.info("Notifications allowed: \(granted)")
        }
    }

    /// `retry` lists the failed files (adds a Retry button); `opensSettings` makes a click open Settings.
    func post(title: String, body: String, openURL: URL? = nil, retry: [URL] = [], opensSettings: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var info: [String: Any] = [:]
        if let openURL { info["url"] = openURL.absoluteString }
        if !retry.isEmpty {
            info["paths"] = retry.map(\.path)
            content.categoryIdentifier = Self.failedCategory
        }
        if opensSettings { info["settings"] = true }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show banners even while our Settings window is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let url = (info["url"] as? String).flatMap { URL(string: $0) }
        let paths = info["paths"] as? [String] ?? []
        let opensSettings = info["settings"] as? Bool ?? false
        await handle(action: action, url: url, paths: paths, opensSettings: opensSettings)
    }

    private func handle(action: String, url: URL?, paths: [String], opensSettings: Bool) {
        if action == Self.retryAction {
            onRetry(paths.map { URL(fileURLWithPath: $0) })
        } else if opensSettings {
            onOpenSettings()
        } else if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
