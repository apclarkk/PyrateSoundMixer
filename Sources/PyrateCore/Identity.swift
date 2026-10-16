import Foundation

/// Stable identity for an audio source as the user thinks of it: an application,
/// not a process. Survives app restarts, so preferences can be matched back.
public struct SourceID: Hashable, Codable, Sendable, CustomStringConvertible, CodingKeyRepresentable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static func bundle(_ bundleID: String) -> SourceID { SourceID(bundleID) }
    public static func path(_ path: String) -> SourceID { SourceID("path:" + path) }
    public static let sharedWebKit = SourceID("shared:com.apple.WebKit")

    public var description: String { rawValue }

    public var codingKey: CodingKey { AnyKey(rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.rawValue = codingKey.stringValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Stable identity for an audio device. Uses the Core Audio device UID, never the
/// display name, so two devices called "Headphones" are never confused.
public struct DeviceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let uid: String

    public init(uid: String) { self.uid = uid }

    public var description: String { uid }

    public init(from decoder: Decoder) throws {
        uid = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uid)
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
