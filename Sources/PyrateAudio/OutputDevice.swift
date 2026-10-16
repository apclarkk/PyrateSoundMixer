import AudioToolbox
import CoreAudio
import Foundation
import PyrateCore

public enum TransportKind: String, Sendable {
    case builtIn, usb, bluetooth, display, airPlay, thunderbolt, aggregate, virtual, other

    init(_ raw: UInt32) {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: self = .display
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        default: self = .other
        }
    }

    public var symbolName: String {
        switch self {
        case .builtIn: return "laptopcomputer"
        case .usb: return "cable.connector"
        case .bluetooth: return "headphones"
        case .display: return "display"
        case .airPlay: return "airplayaudio"
        case .thunderbolt: return "bolt.horizontal"
        case .aggregate: return "square.stack.3d.up"
        case .virtual: return "waveform"
        case .other: return "hifispeaker"
        }
    }
}

public struct OutputDevice: Identifiable, Equatable, Sendable {
    public var objectID: AudioObjectID
    public var id: DeviceID
    public var name: String
    public var transport: TransportKind
    public var isAlive: Bool

    /// Prefix for the private aggregate devices our own tap engines create.
    static let ownedUIDPrefix = "org.pyratesounds.tap."
}

/// Volume and mute of one output device, with what it actually supports.
public struct DeviceVolume: Equatable, Sendable {
    public var level: Double
    public var isMuted: Bool
    public var capabilities: DeviceCapabilities
}

public struct DeviceDetails: Equatable, Sendable {
    public var sampleRate: Double
    public var outputChannels: Int
    public var inputChannels: Int
    public var stereoPair: [Int]
}

/// Reads and writes device level and output selection. Stateless; listening is
/// done by `DeviceMonitor`.
public enum DeviceControl {
    static let mainVolume = CAProperty.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    static let mute = CAProperty.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    static let inputVolume = CAProperty.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeInput)
    static let inputMute = CAProperty.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
    static let defaultOutput = CAProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
    static let defaultInput = CAProperty.address(kAudioHardwarePropertyDefaultInputDevice)
    static let devices = CAProperty.address(kAudioHardwarePropertyDevices)

    public static func outputDevices() -> [OutputDevice] {
        let ids = (try? CAProperty.array(AudioObjectID(kAudioObjectSystemObject), devices, of: AudioObjectID.self)) ?? []
        return ids.compactMap { describe($0, scope: kAudioDevicePropertyScopeOutput) }
    }

    /// Devices with input streams (microphones, interfaces). Same type as outputs.
    public static func inputDevices() -> [OutputDevice] {
        let ids = (try? CAProperty.array(AudioObjectID(kAudioObjectSystemObject), devices, of: AudioObjectID.self)) ?? []
        return ids.compactMap { describe($0, scope: kAudioDevicePropertyScopeInput) }
    }

    static func describe(_ id: AudioObjectID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> OutputDevice? {
        let streams = CAProperty.address(kAudioDevicePropertyStreams, scope: scope)
        guard let outStreams = try? CAProperty.array(id, streams, of: AudioStreamID.self), !outStreams.isEmpty,
              let uid = try? CAProperty.string(id, CAProperty.address(kAudioDevicePropertyDeviceUID)),
              !uid.hasPrefix(OutputDevice.ownedUIDPrefix) else { return nil }
        let name = (try? CAProperty.string(id, CAProperty.address(kAudioObjectPropertyName))) ?? "Unknown Device"
        let transport = (try? CAProperty.get(id, CAProperty.address(kAudioDevicePropertyTransportType), default: UInt32(0))) ?? 0
        let alive = (try? CAProperty.get(id, CAProperty.address(kAudioDevicePropertyDeviceIsAlive), default: UInt32(1))) ?? 1
        return OutputDevice(objectID: id, id: DeviceID(uid: uid), name: name, transport: TransportKind(transport), isAlive: alive != 0)
    }

    public static func defaultOutputID() -> AudioObjectID {
        (try? CAProperty.get(AudioObjectID(kAudioObjectSystemObject), defaultOutput, default: AudioObjectID(kAudioObjectUnknown)))
            ?? AudioObjectID(kAudioObjectUnknown)
    }

    public static func setDefaultOutput(_ id: AudioObjectID) throws {
        try CAProperty.set(AudioObjectID(kAudioObjectSystemObject), defaultOutput, id)
    }

    public static func defaultInputID() -> AudioObjectID {
        (try? CAProperty.get(AudioObjectID(kAudioObjectSystemObject), defaultInput, default: AudioObjectID(kAudioObjectUnknown)))
            ?? AudioObjectID(kAudioObjectUnknown)
    }

    public static func setDefaultInput(_ id: AudioObjectID) throws {
        try CAProperty.set(AudioObjectID(kAudioObjectSystemObject), defaultInput, id)
    }

    /// Input gain and mute of a device, with what it actually supports.
    public static func inputLevel(of id: AudioObjectID) -> DeviceVolume {
        let alive = (try? CAProperty.get(id, CAProperty.address(kAudioDevicePropertyDeviceIsAlive), default: UInt32(1))) ?? 0
        let volumeSettable = CAProperty.isSettable(id, inputVolume)
        let muteSettable = CAProperty.isSettable(id, inputMute)
        let level = (try? CAProperty.get(id, inputVolume, default: Float32(1))) ?? 1
        let muted = muteSettable ? ((try? CAProperty.get(id, inputMute, default: UInt32(0))) ?? 0) != 0 : false
        return DeviceVolume(
            level: Double(level), isMuted: muted,
            capabilities: .derive(isAlive: alive != 0, volumeSettable: volumeSettable, muteSettable: muteSettable))
    }

    public static func setInputLevel(_ level: Double, of id: AudioObjectID) throws {
        try CAProperty.set(id, inputVolume, Float32(min(max(level, 0), 1)))
    }

    public static func setInputMuted(_ muted: Bool, of id: AudioObjectID) throws {
        try CAProperty.set(id, inputMute, UInt32(muted ? 1 : 0))
    }

    /// Technical details for diagnostics.
    public static func details(of id: AudioObjectID) -> DeviceDetails {
        func channels(_ scope: AudioObjectPropertyScope) -> Int {
            let address = CAProperty.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
            var addr = address
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
            let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            return list.reduce(0) { $0 + Int($1.mNumberChannels) }
        }
        let rate = (try? CAProperty.get(id, CAProperty.address(kAudioDevicePropertyNominalSampleRate), default: Float64(0))) ?? 0
        let stereo = preferredStereoChannels(of: id)
        return DeviceDetails(sampleRate: rate, outputChannels: channels(kAudioDevicePropertyScopeOutput),
                             inputChannels: channels(kAudioDevicePropertyScopeInput), stereoPair: [stereo.0, stereo.1])
    }

    public static func volume(of id: AudioObjectID) -> DeviceVolume {
        let alive = (try? CAProperty.get(id, CAProperty.address(kAudioDevicePropertyDeviceIsAlive), default: UInt32(1))) ?? 0
        let volumeSettable = CAProperty.isSettable(id, mainVolume)
        let muteSettable = CAProperty.isSettable(id, mute)
        let level = (try? CAProperty.get(id, mainVolume, default: Float32(1))) ?? 1
        let muted = muteSettable ? ((try? CAProperty.get(id, mute, default: UInt32(0))) ?? 0) != 0 : false
        return DeviceVolume(
            level: Double(level),
            isMuted: muted,
            capabilities: .derive(isAlive: alive != 0, volumeSettable: volumeSettable, muteSettable: muteSettable)
        )
    }

    public static func setVolume(_ level: Double, of id: AudioObjectID) throws {
        try CAProperty.set(id, mainVolume, Float32(min(max(level, 0), 1)))
    }

    public static func setMuted(_ muted: Bool, of id: AudioObjectID) throws {
        try CAProperty.set(id, mute, UInt32(muted ? 1 : 0))
    }

    /// The 1-based channel pair macOS uses for stereo on this device.
    static func preferredStereoChannels(of id: AudioObjectID) -> (Int, Int) {
        let address = CAProperty.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioDevicePropertyScopeOutput)
        guard let pair = try? CAProperty.array(id, address, of: UInt32.self), pair.count == 2,
              pair[0] > 0, pair[1] > 0 else { return (1, 2) }
        return (Int(pair[0]), Int(pair[1]))
    }

    static func objectID(forUID uid: String) -> AudioObjectID? {
        outputDevices().first { $0.id.uid == uid }?.objectID
    }
}

/// Watches the device list, the default output, and the default output's level.
@MainActor
public final class DeviceMonitor {
    public var onChange: (() -> Void)?

    private var listListener: PropertyListener?
    private var defaultListener: PropertyListener?
    private var deviceListeners: [PropertyListener] = []
    private var watchedDevice: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var defaultInputListener: PropertyListener?
    private var inputListeners: [PropertyListener] = []
    private var watchedInput: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    public init() {}

    public func start() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        listListener = PropertyListener(object: system, address: DeviceControl.devices) { [weak self] in
            self?.changed()
        }
        defaultListener = PropertyListener(object: system, address: DeviceControl.defaultOutput) { [weak self] in
            self?.changed()
        }
        defaultInputListener = PropertyListener(object: system, address: DeviceControl.defaultInput) { [weak self] in
            self?.changed()
        }
        rewatchDefaultDevice()
    }

    private func changed() {
        rewatchDefaultDevice()
        onChange?()
    }

    private func rewatchDefaultDevice() {
        let input = DeviceControl.defaultInputID()
        if input != watchedInput {
            watchedInput = input
            inputListeners = [DeviceControl.inputVolume, DeviceControl.inputMute].compactMap { address in
                PropertyListener(object: input, address: address) { [weak self] in self?.onChange?() }
            }
        }
        let current = DeviceControl.defaultOutputID()
        guard current != watchedDevice else { return }
        watchedDevice = current
        deviceListeners = [
            DeviceControl.mainVolume,
            DeviceControl.mute,
            CAProperty.address(kAudioDevicePropertyDeviceIsAlive),
        ].compactMap { address in
            PropertyListener(object: current, address: address) { [weak self] in self?.onChange?() }
        }
    }
}
