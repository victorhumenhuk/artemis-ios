//  ArtemisLog.swift
//  Lightweight logging so integration failures are visible (console + the
//  hidden debug screen). Never logs transcript content or anything sensitive.

import Foundation
import os

enum ArtemisLog {
    private static let logger = Logger(subsystem: "com.artemis.app", category: "artemis")

    /// Ring buffer of recent lines for the debug screen.
    @MainActor private(set) static var recent: [String] = []

    static func info(_ msg: String) { emit("ℹ️", msg); logger.info("\(msg, privacy: .public)") }
    static func warn(_ msg: String) { emit("⚠️", msg); logger.warning("\(msg, privacy: .public)") }
    static func error(_ msg: String) { emit("⛔️", msg); logger.error("\(msg, privacy: .public)") }

    private static func emit(_ icon: String, _ msg: String) {
        Task { @MainActor in
            recent.append("\(icon) \(msg)")
            if recent.count > 60 { recent.removeFirst(recent.count - 60) }
        }
    }
}
