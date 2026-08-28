//
//  DebugLogger.swift
//  2FHey
//
//  Opt-in debug logging to ~/Documents/2FHey_Debug.log.
//

import Foundation

class DebugLogger {
    static let shared = DebugLogger()

    private let logFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("2FHey_Debug.log")
    private let queue = DispatchQueue(label: "com.sofriendly.2fhey.debugLogger", qos: .utility)
    private let dateFormatter: DateFormatter

    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    func log(_ message: String, category: String = "INFO", data: Any? = nil) {
        guard AppStateManager.shared.debugLoggingEnabled else { return }

        queue.async { [self] in
            guard let logFileURL else { return }
            var entry = "[\(dateFormatter.string(from: Date()))] [\(category)] \(message)"
            if let data {
                entry += "\n  Data: \(String(describing: data))"
            }
            entry += "\n"

            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                try? header().write(to: logFileURL, atomically: true, encoding: .utf8)
            }
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL), let data = entry.data(using: .utf8) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
            print(entry)
        }
    }

    func clearLog() {
        queue.async { [self] in
            guard let logFileURL else { return }
            try? header().write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }

    func getLogFilePath() -> String? {
        logFileURL?.path
    }

    private func header() -> String {
        "2FHey Debug Log\nStarted: \(dateFormatter.string(from: Date()))\n" + String(repeating: "=", count: 80) + "\n"
    }
}
