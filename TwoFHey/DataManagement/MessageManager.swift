//
//  MessageManager.swift
//  2FHey
//
//  Watches the iMessage database (chat.db) for new messages and publishes any
//  that contain a one-time code.
//

import Foundation
import Combine
import SQLite

typealias Expression = SQLite.Expression

class MessageManager: ObservableObject, MessageSource {
    @Published var messages: [MessageWithParsedOTP] = []
    var messagesPublisher: AnyPublisher<[MessageWithParsedOTP], Never> { $messages.eraseToAnyPublisher() }

    private let otpParser: OTPParser
    private var processedGuids: Set<String> = []
    private var lastProcessedRowId = 0

    private var walFileMonitor: DispatchSourceFileSystemObject?
    private var syncWorkItem: DispatchWorkItem?
    private let syncDebounceInterval: TimeInterval = 0.3

    private var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
    }

    init(withOTPParser otpParser: OTPParser) {
        self.otpParser = otpParser
    }

    deinit {
        syncWorkItem?.cancel()
        stopListening()
    }

    // MARK: - MessageSource

    func startListening() {
        initializeLastProcessedRowId()
        syncMessages()
        setupWALFileMonitor()
    }

    func stopListening() {
        walFileMonitor?.cancel()
        walFileMonitor = nil
    }

    func reset() {
        syncWorkItem?.cancel()
        syncWorkItem = nil
        stopListening()
        messages = []
        processedGuids = []
        lastProcessedRowId = 0
        startListening()
    }

    func injectTestMessage(_ text: String) {
        let message = Message(rowId: 0, guid: UUID().uuidString, text: text, handle: "+15555551234", group: nil, fromMe: false)
        guard let parsedOTP = otpParser.parse(text) else {
            print("Failed to parse test message: \(text)")
            return
        }
        messages.append((message, parsedOTP))
    }

    // MARK: - Database sync

    private func initializeLastProcessedRowId() {
        guard AppStateManager.shared.hasFullDiskAccess() == .authorized else { return }
        do {
            let db = try Connection(databaseURL.absoluteString)
            let ROWID = Expression<Int>("ROWID")
            if let maxRow = try db.pluck(Table("message").select(ROWID).order(ROWID.desc).limit(1)) {
                lastProcessedRowId = maxRow[ROWID]
            }
        } catch {
            DebugLogger.shared.log("Failed to initialize lastProcessedRowId", category: "ERROR", data: error)
        }
    }

    private func setupWALFileMonitor() {
        let walPath = databaseURL.path + "-wal"
        let descriptor = open(walPath, O_EVTONLY)
        guard descriptor >= 0 else {
            DebugLogger.shared.log("Failed to open WAL file for monitoring", category: "SYNC", data: walPath)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend], queue: .global(qos: .background))

        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.syncWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in self?.syncMessages() }
            self.syncWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + self.syncDebounceInterval, execute: workItem)
        }
        source.setCancelHandler { close(descriptor) }

        walFileMonitor = source
        source.resume()
    }

    @objc func syncMessages() {
        guard AppStateManager.shared.hasFullDiskAccess() == .authorized else { return }
        do {
            let newMessages = try loadMessagesAfterRowId(lastProcessedRowId)
            if let maxRowId = newMessages.map(\.rowId).max() {
                lastProcessedRowId = maxRowId
            }

            let parsed = newMessages
                .filter { !Self.isBlacklisted($0.text) && !processedGuids.contains($0.guid) }
                .compactMap { message -> MessageWithParsedOTP? in
                    processedGuids.insert(message.guid)
                    guard let otp = otpParser.parse(message.text, sender: message.handle) else { return nil }
                    return (message, otp)
                }

            guard !parsed.isEmpty else { return }
            DispatchQueue.main.async { self.messages.append(contentsOf: parsed) }
            DebugLogger.shared.log("Added new OTP messages", category: "SYNC", data: parsed.count)
        } catch {
            let description = String(describing: error)
            if !description.contains("authorization denied") {
                DebugLogger.shared.log("Error during sync", category: "ERROR", data: description)
            }
        }
    }

    private func loadMessagesAfterRowId(_ rowId: Int) throws -> [Message] {
        let db = try Connection(databaseURL.absoluteString)

        let textColumn = Expression<String?>("text")
        let attributedBodyColumn = Expression<Data?>("attributedBody")
        let guidColumn = Expression<String>("guid")
        let cacheRoomnamesColumn = Expression<String?>("cache_roomnames")
        let fromMeColumn = Expression<Bool>("is_from_me")
        let ROWID = Expression<Int>("ROWID")

        let handleTable = Table("handle")
        let handleFrom = handleTable[Expression<String?>("id")]
        let messageTable = Table("message")

        let query = messageTable
            .select(messageTable[guidColumn], messageTable[fromMeColumn], messageTable[textColumn],
                    messageTable[attributedBodyColumn], messageTable[cacheRoomnamesColumn],
                    messageTable[ROWID], handleFrom)
            .join(.leftOuter, handleTable, on: messageTable[Expression<Int>("handle_id")] == handleTable[ROWID])
            .where(messageTable[ROWID] > rowId)
            .order(messageTable[ROWID].asc)
            .limit(100)

        return try db.prepareRowIterator(query).map { row -> Message? in
            guard let handle = row[handleFrom],
                  let text = row[textColumn] ?? Self.parseAttributedBody(row[attributedBodyColumn]) else { return nil }
            return Message(
                rowId: row[ROWID],
                guid: row[guidColumn],
                text: text,
                handle: handle,
                group: row[cacheRoomnamesColumn],
                fromMe: row[fromMeColumn])
        }.compactMap { $0 }
    }

    /// Messages with money amounts or nearly no text are never OTPs.
    private static func isBlacklisted(_ text: String) -> Bool {
        text.count < 5 || ["$", "€", "₹", "¥"].contains(where: text.contains)
    }

    /// On newer macOS versions `text` is often NULL and the content lives in
    /// `attributedBody` as an archived NSAttributedString.
    private static func parseAttributedBody(_ data: Data?) -> String? {
        guard let data else { return nil }

        if let attributed = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data),
           !attributed.string.isEmpty {
            return attributed.string
        }

        // Fallback: scan the raw streamtyped bytes. The message text sits between
        // an "NSString" marker (+8 bytes) and an "NSDictionary" marker (-10 bytes).
        var body = String(decoding: data, as: UTF8.self)
        guard let nsStringRange = body.range(of: "NSString") else { return nil }
        let start = body.index(nsStringRange.upperBound, offsetBy: 8, limitedBy: body.endIndex) ?? body.endIndex
        body = String(body[start...])
        if let nsDictionaryRange = body.range(of: "NSDictionary") {
            let end = body.index(nsDictionaryRange.lowerBound, offsetBy: -10, limitedBy: body.startIndex)
                ?? nsDictionaryRange.lowerBound
            body = String(body[..<end])
        }
        let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Mark as read

    func markMessageAsRead(guid: String) {
        guard AppStateManager.shared.markAsReadEnabled,
              AppStateManager.shared.hasFullDiskAccess() == .authorized else { return }

        do {
            let db = try Connection(databaseURL.absoluteString)
            let message = Table("message").filter(Expression<String>("guid") == guid)
            let dateRead = Int(Date().timeIntervalSinceReferenceDate * 1_000_000_000)
            let updated = try db.run(message.update(
                Expression<Int>("is_read") <- 1,
                Expression<Int>("date_read") <- dateRead))
            guard updated > 0 else { return }

            // Nudge Messages.app to refresh its cached read state.
            for name in ["com.apple.imdpersistence.IMDMessageStore.MessageStoreDidMarkMessagesAsRead",
                         "com.apple.imdpersistence.IMDMessageStore.MessageStoreDidChange"] {
                DistributedNotificationCenter.default().post(name: NSNotification.Name(name), object: nil)
            }
        } catch {
            DebugLogger.shared.log("Failed to mark message as read", category: "ERROR", data: error)
        }
    }
}
