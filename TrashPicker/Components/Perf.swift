// Perf.swift
import Foundation
import os
import QuartzCore

enum Perf {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "perf")
    private static let sp = OSSignposter()

    /// Start a signposted interval. Returns a state token that must be passed to `end`.
    @discardableResult
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        sp.beginInterval(name) // returns state
    }

    /// End a previously started interval.
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        sp.endInterval(name, state)
    }

    /// Simple console mark.
    static func mark(_ message: String) {
        log.info("\(message, privacy: .public)")
    }

    /// Inline timing helper.
    static func time<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        let t0 = CACurrentMediaTime()
        let result = try work()
        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        log.info("\(label, privacy: .public) took \(ms) ms")
        return result
    }
}
