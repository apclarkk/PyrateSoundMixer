import Foundation

/// Turns a noisy, changing set of discovered sources into a calm list of rows.
///
/// Discovery state says what exists right now. This type decides what to show:
/// rows linger for a short grace period after their source vanishes (so a brief
/// gap between tracks does not make a row flicker), new rows are appended rather
/// than inserted, and the row the user is interacting with is never removed.
public struct SourceListStabilizer: Sendable {
    public enum Presence: Equatable, Sendable {
        case present
        case departing(since: Date)
    }

    public struct Row: Equatable, Sendable {
        public var id: SourceID
        public var presence: Presence
    }

    public var gracePeriod: TimeInterval
    public private(set) var order: [SourceID] = []
    private var presence: [SourceID: Presence] = [:]
    public var interacting: SourceID?

    public init(gracePeriod: TimeInterval = 4) {
        self.gracePeriod = gracePeriod
    }

    /// Feeds the latest discovered set. Returns true if the visible rows changed.
    @discardableResult
    public mutating func update(discovered: [SourceID], now: Date = Date()) -> Bool {
        let before = rows()
        let current = Set(discovered)

        for id in discovered where presence[id] == nil {
            order.append(id)
        }
        for id in discovered {
            presence[id] = .present
        }
        for id in order where !current.contains(id) {
            if case .present = presence[id] {
                presence[id] = .departing(since: now)
            }
        }
        prune(now: now)
        return rows() != before
    }

    /// Removes rows whose grace period has elapsed. Call periodically.
    @discardableResult
    public mutating func prune(now: Date = Date()) -> Bool {
        let before = order.count
        order.removeAll { id in
            guard id != interacting, case .departing(let since)? = presence[id] else { return false }
            if now.timeIntervalSince(since) >= gracePeriod {
                presence[id] = nil
                return true
            }
            return false
        }
        return order.count != before
    }

    public func rows() -> [Row] {
        order.compactMap { id in presence[id].map { Row(id: id, presence: $0) } }
    }

    public func isPresent(_ id: SourceID) -> Bool {
        presence[id] == .present
    }
}

/// Final display ordering: pinned sources first (in pin order, even when they are
/// not playing), then everything else in stable first-seen order.
public enum SourceOrdering {
    public static func arrange(
        visible: [SourceID], pinned: [SourceID], includeIdlePinned: Bool,
        sort: SourceSort = .firstSeen, name: (SourceID) -> String = { $0.rawValue }
    ) -> [SourceID] {
        let visibleSet = Set(visible)
        let pinnedSet = Set(pinned)
        let pinnedRows = pinned.filter { includeIdlePinned || visibleSet.contains($0) }
        var others = visible.filter { !pinnedSet.contains($0) }
        if sort == .name {
            others.sort { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
        }
        return pinnedRows + others
    }
}
