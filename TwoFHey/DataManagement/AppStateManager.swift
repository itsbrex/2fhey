//
//  AppStateManager.swift
//  2FHey
//
//  User settings (backed by UserDefaults), permission checks, and UI constants.
//

import Foundation
import ServiceManagement
import ApplicationServices

enum FullDiskAccessStatus {
    case authorized, denied, unknown
}

enum MessagingPlatform: String {
    case iMessage = "imessage"
    case googleMessages = "googlemessages"
}

enum NotificationPosition: Int, CaseIterable {
    case leftEdgeTop, leftEdgeBottom, rightEdgeTop, rightEdgeBottom

    static let defaultValue: NotificationPosition = .leftEdgeTop

    var name: String {
        switch self {
        case .leftEdgeTop: return "Left Edge, Top"
        case .leftEdgeBottom: return "Left Edge, Bottom"
        case .rightEdgeTop: return "Right Edge, Top"
        case .rightEdgeBottom: return "Right Edge, Bottom"
        }
    }
}

struct UIConstants {
    static let codePopupDuration: TimeInterval = 5
    static let codePopupWindowSize = CGSize(width: 300, height: 150)
    static let codePopupMargin: CGFloat = 15
}

class AppStateManager {
    static let shared = AppStateManager()

    private init() {}

    private let defaults = UserDefaults.standard
    private static let keyPrefix = "com.sofriendly.2fhey."
    private static let autoLauncherBundleID = "com.sofriendly.2fhey.AutoLauncher"

    private func bool(_ key: String) -> Bool { defaults.bool(forKey: Self.keyPrefix + key) }
    private func set(_ value: Any?, _ key: String) { defaults.set(value, forKey: Self.keyPrefix + key) }

    // MARK: - Permissions

    func hasFullDiskAccess() -> FullDiskAccessStatus {
        let chatDB = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
        guard FileManager.default.fileExists(atPath: chatDB.path) else { return .unknown }
        return (try? Data(contentsOf: chatDB)) != nil ? .authorized : .denied
    }

    func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: false] as CFDictionary)
    }

    /// Prompts the user for Accessibility permission.
    static func acquireAccessibilityPrivileges() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true] as CFDictionary)
    }

    func isGoogleMessagesAppInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Google Messages.app")
    }

    // MARK: - Settings

    var hasSetup: Bool {
        get { bool("hasSetup") }
        set { set(newValue, "hasSetup") }
    }

    var shouldLaunchOnLogin: Bool {
        get { bool("shouldAutoLaunch") }
        set {
            set(newValue, "shouldAutoLaunch")
            SMLoginItemSetEnabled(Self.autoLauncherBundleID as CFString, newValue)
        }
    }

    var globalShortcutEnabled: Bool {
        get { bool("globalShortcutEnabled") }
        set { set(newValue, "globalShortcutEnabled") }
    }

    var autoPasteEnabled: Bool {
        get { bool("autoPasteEnabled") }
        set { set(newValue, "autoPasteEnabled") }
    }

    var showNotificationOverlay: Bool {
        get { defaults.object(forKey: Self.keyPrefix + "showNotificationOverlay") == nil ? true : bool("showNotificationOverlay") }
        set { set(newValue, "showNotificationOverlay") }
    }

    var useNativeNotifications: Bool {
        get { bool("useNativeNotifications") }
        set { set(newValue, "useNativeNotifications") }
    }

    var markAsReadEnabled: Bool {
        get { bool("markAsReadEnabled") }
        set { set(newValue, "markAsReadEnabled") }
    }

    var debugLoggingEnabled: Bool {
        get { bool("debugLoggingEnabled") }
        set { set(newValue, "debugLoggingEnabled") }
    }

    var notificationPosition: NotificationPosition {
        get {
            guard let raw = defaults.object(forKey: Self.keyPrefix + "notificationPosition") as? Int else {
                return .defaultValue
            }
            return NotificationPosition(rawValue: raw) ?? .defaultValue
        }
        set { set(newValue.rawValue, "notificationPosition") }
    }

    /// Seconds before the clipboard is restored. 0 disables restoring.
    var restoreContentsDelayTime: Int {
        get { defaults.object(forKey: Self.keyPrefix + "restoreContentsDelayTime") as? Int ?? 5 }
        set { set(newValue, "restoreContentsDelayTime") }
    }

    var restoreContentsEnabled: Bool { restoreContentsDelayTime > 0 }

    var messagingPlatform: MessagingPlatform {
        get {
            guard let raw = defaults.string(forKey: Self.keyPrefix + "messagingPlatform") else { return .iMessage }
            return MessagingPlatform(rawValue: raw) ?? .iMessage
        }
        set { set(newValue.rawValue, "messagingPlatform") }
    }

    var googleMessagesAppInstalled: Bool {
        get { bool("googleMessagesAppInstalled") }
        set { set(newValue, "googleMessagesAppInstalled") }
    }
}
