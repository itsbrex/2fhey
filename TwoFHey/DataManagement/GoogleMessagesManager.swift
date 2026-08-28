//
//  GoogleMessagesManager.swift
//  2FHey
//
//  Receives notifications from the Google Messages desktop app via the local
//  NotificationServer and publishes any that contain a one-time code.
//

import Foundation
import Combine

class GoogleMessagesManager: ObservableObject, MessageSource {
    @Published var messages: [MessageWithParsedOTP] = []
    var messagesPublisher: AnyPublisher<[MessageWithParsedOTP], Never> { $messages.eraseToAnyPublisher() }

    private let otpParser: OTPParser
    private var processedIds: Set<String> = []
    private let cacheKey = "com.sofriendly.2fhey.googleMessagesCache"
    private let maxCachedMessages = 10

    private struct CachedMessage: Codable {
        let id: String
        let text: String
        let code: String
        let service: String?
    }

    init(withOTPParser otpParser: OTPParser) {
        self.otpParser = otpParser
        loadCachedMessages()
    }

    deinit {
        stopListening()
    }

    // MARK: - MessageSource

    func startListening() {
        NotificationServer.shared.onNotificationReceived = { [weak self] title, body, id in
            self?.handleNotification(title: title, body: body, id: id)
        }
        NotificationServer.shared.start()
    }

    func stopListening() {
        NotificationServer.shared.stop()
        NotificationServer.shared.onNotificationReceived = nil
    }

    func reset() {
        stopListening()
        messages = []
        processedIds = []
        UserDefaults.standard.removeObject(forKey: cacheKey)
        startListening()
    }

    func injectTestMessage(_ text: String) {
        guard let parsedOTP = otpParser.parse(text) else {
            print("Failed to parse test message: \(text)")
            return
        }
        messages.append((makeMessage(id: UUID().uuidString, text: text), parsedOTP))
    }

    func markMessageAsRead(guid: String) {
        // Not supported for Google Messages.
    }

    // MARK: - Notification handling

    private func handleNotification(title: String, body: String, id: String) {
        guard !processedIds.contains(id) else { return }
        processedIds.insert(id)

        // The title is the sender (often a phone number or short code), so it is
        // never searched for codes — only used to exclude the sender's own number.
        let parsedOTP: ParsedOTP?
        let displayText: String
        if !body.isEmpty {
            parsedOTP = otpParser.parse(body, sender: title)
            displayText = body
        } else {
            parsedOTP = otpParser.parse(title)
            displayText = title
        }

        guard let parsedOTP else {
            DebugLogger.shared.log("No OTP found in notification", category: "GOOGLE_MESSAGES", data: String(displayText.prefix(100)))
            return
        }

        DispatchQueue.main.async {
            self.messages.append((self.makeMessage(id: id, text: displayText), parsedOTP))
            self.saveCachedMessages()
        }
    }

    private func makeMessage(id: String, text: String) -> Message {
        Message(rowId: 0, guid: id, text: text, handle: "Google Messages", group: nil, fromMe: false)
    }

    // MARK: - Cache

    private func loadCachedMessages() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode([CachedMessage].self, from: data) else { return }
        for entry in cached {
            processedIds.insert(entry.id)
            messages.append((makeMessage(id: entry.id, text: entry.text), ParsedOTP(service: entry.service, code: entry.code)))
        }
    }

    private func saveCachedMessages() {
        let cached = messages.suffix(maxCachedMessages).map { message, otp in
            CachedMessage(id: message.guid, text: message.text, code: otp.code, service: otp.service)
        }
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
}
