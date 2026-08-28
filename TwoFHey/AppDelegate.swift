//
//  AppDelegate.swift
//  2FHey
//

import Cocoa
import Combine
import SwiftUI
import HotKey
import UserNotifications

class OverlayWindow: NSWindow {
    init(line1: String?, line2: String?) {
        let size = UIConstants.codePopupWindowSize
        let margin = UIConstants.codePopupMargin
        let screen = NSScreen.main?.visibleFrame ?? NSRect()

        let x: CGFloat
        let y: CGFloat
        switch AppStateManager.shared.notificationPosition {
        case .leftEdgeTop: (x, y) = (margin, screen.maxY - margin - size.height)
        case .leftEdgeBottom: (x, y) = (margin, margin)
        case .rightEdgeTop: (x, y) = (screen.maxX - margin - size.width, screen.maxY - margin - size.height)
        case .rightEdgeBottom: (x, y) = (screen.maxX - margin - size.width, margin)
        }

        super.init(contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
                   styleMask: [.closable, .fullSizeContentView, .borderless], backing: .buffered, defer: false)

        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        contentView = NSHostingView(rootView: OverlayView(line1: line1, line2: line2))
        makeKeyAndOrderFront(nil)

        Timer.scheduledTimer(withTimeInterval: UIConstants.codePopupDuration, repeats: false) { [weak self] _ in
            self?.close()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let otpParser = OTPParser()
    private var messageSource: MessageSource?

    private var statusBarItem: NSStatusItem!
    private var onboardingWindow: NSWindow?
    private var overlayWindow: OverlayWindow?
    private var hotKey: HotKey?
    private var cancellables: Set<AnyCancellable> = []

    private var mostRecentMessages: [MessageWithParsedOTP] = []
    private var lastNotificationMessage: Message?
    private var shouldShowNotificationOverlay = false
    private var originalClipboardContents: String?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let icon = NSImage(named: "TrayIcon")!
        icon.isTemplate = true
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusBarItem.button?.image = icon
        statusBarItem.isVisible = true

        NSApp.activate(ignoringOtherApps: true)

        if AppStateManager.shared.globalShortcutEnabled {
            setupGlobalKeyShortcut()
        }

        startMessageSource()
        setupClipboardRestoreOnPaste()
        setupNotifications()

        if !AppStateManager.shared.hasSetup {
            AppStateManager.shared.shouldLaunchOnLogin = true
            AppStateManager.shared.globalShortcutEnabled = true
            AppStateManager.shared.hasSetup = true
            openOnboardingWindow()
        } else if AppStateManager.shared.messagingPlatform == .iMessage,
                  AppStateManager.shared.hasFullDiskAccess() != .authorized || !AppStateManager.shared.hasAccessibilityPermission() {
            openOnboardingWindow()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Message source

    func startMessageSource() {
        messageSource?.stopListening()

        switch AppStateManager.shared.messagingPlatform {
        case .iMessage: messageSource = MessageManager(withOTPParser: otpParser)
        case .googleMessages: messageSource = GoogleMessagesManager(withOTPParser: otpParser)
        }

        messageSource?.messagesPublisher.sink { [weak self] messages in
            guard let self else { return }
            if let newest = messages.last, newest.0 != self.lastNotificationMessage, self.shouldShowNotificationOverlay {
                self.showOverlayForMessage(newest)
            }
            self.mostRecentMessages = messages.suffix(3)
            self.refreshMenu()
            self.shouldShowNotificationOverlay = true
        }.store(in: &cancellables)
        messageSource?.startListening()
    }

    private func showOverlayForMessage(_ message: MessageWithParsedOTP) {
        overlayWindow?.close()
        overlayWindow = nil
        lastNotificationMessage = message.0

        originalClipboardContents = message.1.copyToClipboard()
        messageSource?.markMessageAsRead(guid: message.0.guid)

        if AppStateManager.shared.autoPasteEnabled && AppStateManager.shared.hasAccessibilityPermission() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Self.sendCommandV() }
        }

        restoreClipboardContents(withDelay: AppStateManager.shared.restoreContentsDelayTime)

        if AppStateManager.shared.useNativeNotifications {
            sendNativeNotification(code: message.1.code, service: message.1.service)
        } else if AppStateManager.shared.showNotificationOverlay {
            overlayWindow = OverlayWindow(line1: message.1.code, line2: "Copied to Clipboard")
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    // MARK: - Clipboard

    /// Restores the clipboard after a delay. Multiple calls race; whichever fires
    /// first restores, the rest become no-ops.
    private func restoreClipboardContents(withDelay delaySeconds: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delaySeconds)) {
            guard let contents = self.originalClipboardContents else { return }
            NSPasteboard.general.setString(contents, forType: .string)
            self.originalClipboardContents = nil
            if !AppStateManager.shared.useNativeNotifications && AppStateManager.shared.showNotificationOverlay {
                self.overlayWindow = OverlayWindow(line1: "Clipboard Restored", line2: nil)
            }
        }
    }

    /// After the user pastes (⌘V), restore the clipboard sooner.
    private func setupClipboardRestoreOnPaste() {
        guard AppStateManager.shared.restoreContentsEnabled else { return }
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            if event.modifierFlags.contains(.command) && event.keyCode == 9 {
                self.restoreClipboardContents(withDelay: 5)
            }
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                print("Error requesting notification permission: \(error)")
            }
        }
    }

    private func sendNativeNotification(code: String, service: String?) {
        let content = UNMutableNotificationContent()
        content.title = "2FA Code Copied"
        content.body = service.map { "\(code) - \($0)" } ?? code
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Onboarding

    private func openOnboardingWindow() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Setup 2FHey"
            window.contentView = NSHostingView(rootView: OnboardingView())
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("OnboardingWindow")
            window.minSize = NSSize(width: 600, height: 500)
            onboardingWindow = window
        }
        onboardingWindow?.center()
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu

    private func refreshMenu() {
        statusBarItem.menu = createMenu()
    }

    private func toggleItem(_ title: String, action: Selector, on: Bool, toolTip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = on ? .on : .off
        item.toolTip = toolTip
        return item
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()
        let state = AppStateManager.shared

        let statusText: String
        switch state.messagingPlatform {
        case .iMessage:
            statusText = state.hasFullDiskAccess() == .authorized ? "🟢 Connected to iMessage" : "⚠️ Setup 2FHey"
        case .googleMessages:
            statusText = state.isGoogleMessagesAppInstalled() ? "🟢 Connected to Google Messages" : "⚠️ Setup Google Messages"
        }
        menu.addItem(withTitle: statusText, action: #selector(onPressSetup), keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Recent", action: nil, keyEquivalent: "")
        for (index, (_, otp)) in mostRecentMessages.enumerated() {
            let item = NSMenuItem(title: "\(otp.code) - \(otp.service ?? "Unknown")", action: #selector(onPressCode), keyEquivalent: "")
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())

        if state.messagingPlatform == .iMessage {
            let resync = NSMenuItem(title: "Resync", action: #selector(self.resync), keyEquivalent: "")
            resync.toolTip = "If 2FHey ever misses a message, use this option to sync recent messages and copy the latest code to your clipboard"
            menu.addItem(resync)
        }

        let settings = NSMenu()
        settings.addItem(toggleItem("Use Native Notifications", action: #selector(onPressUseNativeNotifications),
                                    on: state.useNativeNotifications,
                                    toolTip: "Use macOS native notifications instead of custom overlay (follows Do Not Disturb settings)"))

        if !state.useNativeNotifications {
            let positionMenu = NSMenu()
            for position in NotificationPosition.allCases {
                let item = toggleItem(position.name, action: #selector(onPressNotificationPosition), on: state.notificationPosition == position)
                item.representedObject = position
                positionMenu.addItem(item)
            }
            let positionItem = NSMenuItem(title: "Notification Position", action: nil, keyEquivalent: "")
            positionItem.toolTip = "Select where notifications will appear on the screen"
            positionItem.submenu = positionMenu
            settings.addItem(positionItem)

            settings.addItem(toggleItem("Show Notification Overlay", action: #selector(onPressShowOverlay),
                                        on: state.showNotificationOverlay,
                                        toolTip: "Show a notification overlay when a code is copied (disable for privacy during screen recordings)"))
        }

        settings.addItem(toggleItem("Keyboard Shortcuts", action: #selector(onPressKeyboardShortcuts),
                                    on: state.globalShortcutEnabled,
                                    toolTip: "Disable keyboard shortcuts if 2FHey uses the same keyboard shortcuts as another app"))
        settings.addItem(toggleItem("Auto-Paste Codes", action: #selector(onPressAutoPaste), on: state.autoPasteEnabled,
                                    toolTip: "Automatically paste codes into focused text field (requires accessibility permissions)"))

        if state.messagingPlatform == .iMessage {
            settings.addItem(toggleItem("Mark Messages as Read", action: #selector(onPressMarkAsRead), on: state.markAsReadEnabled,
                                        toolTip: "Automatically mark OTP messages as read in iMessage after copying the code"))
        }

        let restoreMenu = NSMenu()
        for delay in [0, 5, 10, 15, 20] {
            let item = toggleItem(delay == 0 ? "Disabled" : "\(delay) sec", action: #selector(onPressRestoreClipboardContents),
                                  on: state.restoreContentsDelayTime == delay)
            item.representedObject = delay
            restoreMenu.addItem(item)
        }
        let restoreItem = toggleItem("Restore Clipboard Contents", action: #selector(onPressRestoreClipboardContents),
                                     on: state.restoreContentsEnabled,
                                     toolTip: "Restore your clipboard to what it was before receiving a code")
        restoreItem.submenu = restoreMenu
        settings.addItem(restoreItem)

        settings.addItem(toggleItem("Open at Login", action: #selector(onPressAutoLaunch), on: state.shouldLaunchOnLogin))

        let hideItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(onPressHideMenuBar), keyEquivalent: "")
        hideItem.toolTip = "Hide the menu bar icon until the app is relaunched"
        settings.addItem(hideItem)

        settings.addItem(.separator())
        let otherPlatform = state.messagingPlatform == .iMessage ? "Google Messages" : "iMessage"
        settings.addItem(withTitle: "Switch to \(otherPlatform)", action: #selector(onPressSwitchPlatform), keyEquivalent: "")

        settings.addItem(.separator())
        settings.addItem(toggleItem("Debug Logging", action: #selector(onPressDebugLogging), on: state.debugLoggingEnabled,
                                    toolTip: "Enable debug logging to troubleshoot issues. Logs are saved to ~/Documents/2FHey_Debug.log"))
        if state.debugLoggingEnabled {
            settings.addItem(withTitle: "Open Debug Log", action: #selector(onPressOpenDebugLog), keyEquivalent: "")
            settings.addItem(withTitle: "Clear Debug Log", action: #selector(onPressClearDebugLog), keyEquivalent: "")
        }

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settings
        menu.addItem(settingsItem)

        #if DEBUG
        menu.addItem(.separator())
        let debugMenu = NSMenu()
        for (name, message) in Self.testMessages {
            let item = NSMenuItem(title: "Test: \(name)", action: #selector(injectTestMessage), keyEquivalent: "")
            item.representedObject = message
            debugMenu.addItem(item)
        }
        let debugItem = NSMenuItem(title: "🐛 Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu
        menu.addItem(debugItem)
        #endif

        menu.addItem(withTitle: "Quit 2FHey", action: #selector(quit), keyEquivalent: "")
        return menu
    }

    // MARK: - Actions

    @objc func resync() {
        shouldShowNotificationOverlay = false
        lastNotificationMessage = nil
        originalClipboardContents = nil
        messageSource?.reset()
    }

    private func setupGlobalKeyShortcut() {
        if AppStateManager.shared.globalShortcutEnabled && hotKey == nil {
            hotKey = HotKey(key: .e, modifiers: [.command, .shift])
            hotKey?.keyDownHandler = { [weak self] in self?.resync() }
        } else if !AppStateManager.shared.globalShortcutEnabled {
            hotKey = nil
        }
    }

    @objc func onPressSetup() { openOnboardingWindow() }

    @objc func onPressSwitchPlatform() {
        AppStateManager.shared.hasSetup = false
        openOnboardingWindow()
    }

    @objc func onPressAutoLaunch() {
        AppStateManager.shared.shouldLaunchOnLogin.toggle()
        refreshMenu()
    }

    @objc func onPressHideMenuBar() {
        let alert = NSAlert()
        alert.messageText = "Hide Menu Bar Icon?"
        alert.informativeText = "The menu bar icon will be hidden until you quit and relaunch 2FHey. You can quit the app using Activity Monitor or by running 'killall 2FHey' in Terminal."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            statusBarItem?.isVisible = false
        }
    }

    @objc func onPressKeyboardShortcuts() {
        AppStateManager.shared.globalShortcutEnabled.toggle()
        refreshMenu()
        setupGlobalKeyShortcut()
    }

    @objc func onPressRestoreClipboardContents(sender: NSMenuItem) {
        AppStateManager.shared.restoreContentsDelayTime = sender.representedObject as? Int ?? 0
        refreshMenu()
    }

    @objc func onPressNotificationPosition(sender: NSMenuItem) {
        guard let position = sender.representedObject as? NotificationPosition else { return }
        AppStateManager.shared.notificationPosition = position
        refreshMenu()
    }

    @objc func onPressAutoPaste() {
        AppStateManager.shared.autoPasteEnabled.toggle()
        refreshMenu()
    }

    @objc func onPressShowOverlay() {
        AppStateManager.shared.showNotificationOverlay.toggle()
        refreshMenu()
    }

    @objc func onPressUseNativeNotifications() {
        AppStateManager.shared.useNativeNotifications.toggle()
        refreshMenu()
    }

    @objc func onPressMarkAsRead() {
        AppStateManager.shared.markAsReadEnabled.toggle()
        refreshMenu()
    }

    @objc func onPressDebugLogging() {
        AppStateManager.shared.debugLoggingEnabled.toggle()
        refreshMenu()
    }

    @objc func onPressOpenDebugLog() {
        if let path = DebugLogger.shared.getLogFilePath() {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }

    @objc func onPressClearDebugLog() {
        DebugLogger.shared.clearLog()
    }

    @objc func onPressCode(_ sender: Any) {
        guard let index = (sender as? NSMenuItem)?.tag, mostRecentMessages.indices.contains(index) else { return }
        originalClipboardContents = mostRecentMessages[index].1.copyToClipboard()
        restoreClipboardContents(withDelay: AppStateManager.shared.restoreContentsDelayTime)
    }

    @objc func injectTestMessage(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? String else { return }
        messageSource?.injectTestMessage(message)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    #if DEBUG
    private static let testMessages = [
        ("Google", "G-123456 is your Google verification code."),
        ("Apple", "Your Apple ID Code is: 654321. Don't share it with anyone."),
        ("Amazon", "123456 is your Amazon OTP. Do not share it with anyone."),
        ("Generic code:", "Your code: 456789"),
        ("Verification code is", "Your verification code is 789012"),
        ("Security code", "Your security code is: 654321"),
        ("Login code", "Your login code: 123456"),
        ("One-time password", "Your one-time password is 987654"),
        ("Validation code", "Your validation code is 456123"),
        ("Confirmation code", "Your confirmation code: 789456"),
        ("JAILATM (use pattern)", "Truist Alerts: To verify the JAILATM CO transaction on card 0323, use 582270. We won't contact you for this code."),
        ("Link verification", "132637 is your Link verification code."),
        ("Alphanumeric", "ABC123 is your verification code"),
        ("Chase", "From: Chase\nWe'll NEVER call you to ask for this code.\nOne-Time Code:12345678\nOnly use this online. Code expires in 30 min."),
        ("Geico alphanumeric", "GEICO: Your verification code is: ABC123. It expires in 10 minutes."),
        ("Vodafone alphanumeric", "Your code is AB12C."),
        ("Chinese (Zhihu)", "【知乎】你的验证码是 700185，此验证码用于登录知乎或重置密码。10 分钟内有效。"),
        ("Chinese (JD)", "【京东】验证码：548393，您正在新设备上登录。"),
        ("Custom: DBS Bank", "Please use SGD-123456 within 3 minutes to authorize this transaction."),
        ("Custom: MIGov", "Your passcode is\n1234-567890"),
        ("Custom: pf-bank", "12345678\nValid 5 minutes. Do not share."),
        ("Custom: idCAT Mobil", "@valid.aoc.cat #654321"),
        ("Custom: FNZ Finvesto", "Ihr Bestätigungscode ist: AB3C45"),
        ("Custom: Cater Allen", "OTP to MAKE A NEW PAYMENT of GBP 9.94 to 560027 & 27613445. Call us if this wasn't you. NEVER share this code, not even with Cater Allen staff 699486"),
        ("Phone number trap", "New login from +1 (415) 555-2671. Your code is 887766."),
    ]
    #endif
}
