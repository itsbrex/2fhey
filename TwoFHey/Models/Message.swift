//
//  Message.swift
//  2FHey
//

import Foundation
import Combine

struct Message: Equatable {
    let rowId: Int
    let guid: String
    let text: String
    let handle: String
    let group: String?
    let fromMe: Bool
}

typealias MessageWithParsedOTP = (Message, ParsedOTP)

/// A source of OTP-bearing messages (iMessage database or Google Messages notifications).
protocol MessageSource: AnyObject {
    var messagesPublisher: AnyPublisher<[MessageWithParsedOTP], Never> { get }
    func startListening()
    func stopListening()
    func reset()
    func injectTestMessage(_ text: String)
    func markMessageAsRead(guid: String)
}
