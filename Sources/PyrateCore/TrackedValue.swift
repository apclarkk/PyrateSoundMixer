import Foundation

/// Where a requested change came from. Phase 1 only uses `user` and `restore`;
/// later phases add profiles and rules so the app can explain why something changed.
public enum ChangeOrigin: Equatable, Codable, Sendable {
    case user
    case restore
    case system
    case profile
    case rule
}

/// Separates what the user asked for from what the system has confirmed.
///
/// Lifecycle: `request` puts a value in flight, `confirm` records what the system
/// reports (clearing the request once it matches), and `fail` drops the request
/// and keeps the confirmed value so the interface never shows a state that is not real.
public struct TrackedValue<Value: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var confirmed: Value?
    public private(set) var requested: Value?
    public private(set) var requestedAt: Date?
    public private(set) var origin: ChangeOrigin?
    public private(set) var failure: String?

    public init(confirmed: Value? = nil) {
        self.confirmed = confirmed
    }

    /// What the interface should show: the in-flight request if any, else the confirmed value.
    public var displayed: Value? { requested ?? confirmed }

    public var isPending: Bool { requested != nil }

    public mutating func request(_ value: Value, origin: ChangeOrigin = .user, at date: Date = Date()) {
        failure = nil
        if value == confirmed {
            requested = nil
            requestedAt = nil
            return
        }
        requested = value
        requestedAt = date
        self.origin = origin
    }

    public mutating func confirm(_ value: Value?) {
        confirmed = value
        if requested == value {
            requested = nil
            requestedAt = nil
        }
    }

    public mutating func fail(_ message: String) {
        requested = nil
        requestedAt = nil
        failure = message
    }

    /// Fails the request if it has been in flight longer than `timeout`.
    @discardableResult
    public mutating func expire(now: Date = Date(), timeout: TimeInterval, message: String) -> Bool {
        guard let requestedAt, now.timeIntervalSince(requestedAt) >= timeout else { return false }
        fail(message)
        return true
    }

    public mutating func clearFailure() { failure = nil }
}
