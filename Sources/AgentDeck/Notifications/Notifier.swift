import Foundation
import UserNotifications
import ServiceManagement

/// System notifications. Clicking one selects the agent (handled by AppDelegate).
final class Notifier: NSObject, @unchecked Sendable {
    private var authorized = false
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static let categoryDefault = "agent"
    static let categoryDecide = "agent.decide"
    static let actionShow = "show"
    static let actionAccept = "accept"
    static let actionReject = "reject"

    func requestAuthorization() {
        guard available else { return }
        let show = UNNotificationAction(identifier: Self.actionShow, title: "Show in AgentDeck", options: [.foreground])
        let accept = UNNotificationAction(identifier: Self.actionAccept, title: "Accept", options: [])
        let reject = UNNotificationAction(identifier: Self.actionReject, title: "Reject", options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryDefault, actions: [show], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.categoryDecide, actions: [accept, reject, show], intentIdentifiers: []),
        ])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] ok, _ in
            self?.authorized = ok
        }
    }

    func post(title: String, body: String, agentID: String, canDecide: Bool = false) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["agentID": agentID]
        content.threadIdentifier = agentID
        content.categoryIdentifier = canDecide ? Self.categoryDecide : Self.categoryDefault
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev" }
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    /// Development aid: `--snapshot <png> [delay]` renders the window for visual checks.
    static let snapshotMode = CommandLine.arguments.contains("--snapshot")
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        guard AppInfo.isBundled else { throw AgentDeckError.unsupported("Launch at login requires running the bundled AgentDeck.app.") }
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
