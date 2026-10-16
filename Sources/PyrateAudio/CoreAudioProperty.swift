import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let context: String

    public var description: String {
        "\(context) failed (\(Self.fourCC(status)))"
    }

    static func fourCC(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes = [UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "'" + String(decoding: bytes, as: UTF8.self) + "'"
        }
        return String(status)
    }
}

@inline(__always)
func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, context: context()) }
}

/// Thin, typed access to Core Audio object properties.
enum CAProperty {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &address),
              AudioObjectIsPropertySettable(object, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, default value: T) throws -> T {
        var address = address
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result),
                  "Reading property \(CoreAudioError.fourCC(OSStatus(bitPattern: address.mSelector)))")
        return result
    }

    static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of _: T.Type) throws -> [T] {
        var address = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Sizing property")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!), "Reading array property")
            initialized = Int(size) / MemoryLayout<T>.stride
        }
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        var address = address
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Reading string property")
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        var value = value
        try check(AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value),
                  "Setting property \(CoreAudioError.fourCC(OSStatus(bitPattern: address.mSelector)))")
    }
}

/// Registers a Core Audio property listener for its lifetime. Callbacks arrive on
/// the main queue, so handlers can touch main-actor state directly.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(object: AudioObjectID, address: AudioObjectPropertyAddress, handler: @escaping @MainActor () -> Void) {
        self.object = object
        self.address = address
        self.block = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &self.address, DispatchQueue.main, block) == noErr else {
            return nil
        }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }
}
