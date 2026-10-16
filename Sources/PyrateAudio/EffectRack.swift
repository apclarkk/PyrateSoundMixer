import AudioToolbox
import Foundation
import PyrateCore

/// What an Apple effect offers, read from the unit itself (main thread, cached).
public struct EffectParameter: Identifiable, Equatable, Sendable {
    public var id: UInt32
    public var name: String
    public var minValue: Float
    public var maxValue: Float
    public var defaultValue: Float
    public var unit: AudioUnitParameterUnit

    public var isBoolean: Bool { unit == .boolean }
    public var isIndexed: Bool { unit == .indexed }
    /// Frequencies feel even on a logarithmic scale.
    public var isLogarithmic: Bool { unit == .hertz && minValue > 0 }
}

public struct EffectDescription: Sendable {
    public var parameters: [EffectParameter]
    public var presets: [(number: Int, name: String)]
    /// Parameter values each factory preset sets.
    public var presetValues: [Int: [UInt32: Float]]
}

@MainActor
public enum AppleEffectLibrary {
    private static var cache: [String: EffectDescription] = [:]
    private static var missing: Set<String> = []

    static func component(_ kind: String) -> AudioComponent? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: AppleEffectCatalog.fourCC(kind),
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        return AudioComponentFindNext(nil, &desc)
    }

    public static func isAvailable(_ kind: String) -> Bool { describe(kind) != nil }

    /// Parameters and presets of an effect, or nil when the unit isn't on this Mac.
    public static func describe(_ kind: String) -> EffectDescription? {
        if let cached = cache[kind] { return cached }
        if missing.contains(kind) { return nil }
        guard let component = component(kind) else { missing.insert(kind); return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else { missing.insert(kind); return nil }
        defer { AudioComponentInstanceDispose(unit) }

        let parameters = parameterIDs(unit).compactMap { id -> EffectParameter? in
            var info = AudioUnitParameterInfo()
            var size = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
            guard AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, id, &info, &size) == noErr else { return nil }
            let name = info.cfNameString.map { $0.takeUnretainedValue() as String } ?? "Parameter \(id)"
            if info.flags.contains(.flag_CFNameRelease) { info.cfNameString?.release() }
            return EffectParameter(id: id, name: name, minValue: info.minValue, maxValue: info.maxValue,
                                   defaultValue: info.defaultValue, unit: info.unit)
        }

        var presets: [(Int, String)] = []
        var presetValues: [Int: [UInt32: Float]] = [:]
        for preset in factoryPresets(unit) {
            presets.append((Int(preset.presetNumber), cleanName(preset.presetName?.takeUnretainedValue() as String? ?? "Preset")))
            var p = preset
            if AudioUnitSetProperty(unit, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0,
                                    &p, UInt32(MemoryLayout<AUPreset>.size)) == noErr {
                var values: [UInt32: Float] = [:]
                for parameter in parameters {
                    var v: AudioUnitParameterValue = 0
                    if AudioUnitGetParameter(unit, parameter.id, kAudioUnitScope_Global, 0, &v) == noErr { values[parameter.id] = v }
                }
                presetValues[Int(preset.presetNumber)] = values
            }
        }
        let description = EffectDescription(parameters: parameters, presets: presets, presetValues: presetValues)
        cache[kind] = description
        return description
    }

    /// "Multi - Cellphone Concert" reads better as "Cellphone Concert".
    static func cleanName(_ name: String) -> String {
        guard let dash = name.firstIndex(of: "-") else { return name }
        let rest = name[name.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    static func parameterIDs(_ unit: AudioUnit) -> [AudioUnitParameterID] {
        var size: UInt32 = 0
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, nil) == noErr,
              size > 0 else { return [] }
        var ids = [AudioUnitParameterID](repeating: 0, count: Int(size) / MemoryLayout<AudioUnitParameterID>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &ids, &size) == noErr else { return [] }
        return ids
    }

    static func factoryPresets(_ unit: AudioUnit) -> [AUPreset] {
        var array: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_FactoryPresets, kAudioUnitScope_Global, 0, &array, &size) == noErr,
              let list = array?.takeUnretainedValue() else { return [] }
        return (0..<CFArrayGetCount(list)).compactMap { i in
            CFArrayGetValueAtIndex(list, i)?.assumingMemoryBound(to: AUPreset.self).pointee
        }
    }
}

/// Where the render callback reads its input from during one render call.
struct RackRenderContext {
    var left: UnsafeMutablePointer<Float>?
    var right: UnsafeMutablePointer<Float>?
}

/// Feeds the current input buffers to an Audio Unit that pulls for input.
private let rackInputCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    let context = refCon.assumingMemoryBound(to: RackRenderContext.self).pointee
    guard let ioData, let left = context.left, let right = context.right else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    let bytes = Int(frameCount) * MemoryLayout<Float>.size
    // No arrays or closures here: this runs on the realtime thread.
    if buffers.count > 0 { fill(&buffers[0], from: left, bytes: bytes) }
    if buffers.count > 1 { fill(&buffers[1], from: right, bytes: bytes) }
    return noErr
}

@inline(__always)
private func fill(_ buffer: inout AudioBuffer, from source: UnsafeMutablePointer<Float>, bytes: Int) {
    if let data = buffer.mData {
        memcpy(data, source, bytes)
    } else {
        buffer.mData = UnsafeMutableRawPointer(source)
    }
    buffer.mDataByteSize = UInt32(bytes)
}

/// A chain of live Apple Audio Units for one source.
///
/// Built and destroyed on the main thread; `process` runs on the realtime thread
/// and touches only preallocated memory and `AudioUnitRender`. Parameter and
/// bypass changes apply to the running units; anything else builds a new rack.
public final class EffectRack: @unchecked Sendable {
    public static let maxFrames = 4096

    public let effects: [RackEffect]
    public let structureKey: [String]
    public let sampleRate: Double
    /// Kinds that couldn't be loaded on this Mac and were skipped.
    public private(set) var skipped: [String] = []

    private let count: Int
    private let units: UnsafeMutablePointer<AudioUnit?>
    private let bypassed: UnsafeMutablePointer<Int32>
    private let context: UnsafeMutablePointer<RackRenderContext>
    private let outLeft: UnsafeMutablePointer<Float>
    private let outRight: UnsafeMutablePointer<Float>
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private var sampleTime: Float64 = 0
    private var unitIndex: [String: Int] = [:]

    @MainActor
    public init(effects: [RackEffect], sampleRate: Double) {
        self.effects = effects
        self.structureKey = effects.map(\.structureKey)
        self.sampleRate = sampleRate
        count = effects.count
        units = .allocate(capacity: max(count, 1))
        units.initialize(repeating: nil, count: max(count, 1))
        bypassed = .allocate(capacity: max(count, 1))
        bypassed.initialize(repeating: 0, count: max(count, 1))
        context = .allocate(capacity: 1)
        context.initialize(to: RackRenderContext())
        outLeft = .allocate(capacity: Self.maxFrames)
        outLeft.initialize(repeating: 0, count: Self.maxFrames)
        outRight = .allocate(capacity: Self.maxFrames)
        outRight.initialize(repeating: 0, count: Self.maxFrames)
        bufferList = AudioBufferList.allocate(maximumBuffers: 2)

        for (index, effect) in effects.enumerated() {
            if let unit = makeUnit(effect) {
                units[index] = unit
                bypassed[index] = effect.isBypassed ? 1 : 0
                unitIndex[effect.id] = index
            } else {
                skipped.append(effect.kind)
            }
        }
    }

    deinit {
        for i in 0..<count {
            if let unit = units[i] {
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
        }
        units.deallocate()
        bypassed.deallocate()
        context.deallocate()
        outLeft.deallocate()
        outRight.deallocate()
        free(bufferList.unsafeMutablePointer)
    }

    @MainActor
    private func makeUnit(_ effect: RackEffect) -> AudioUnit? {
        guard let component = AppleEffectLibrary.component(effect.kind) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else { return nil }

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var maxFrames = UInt32(Self.maxFrames)
        var callback = AURenderCallbackStruct(inputProc: rackInputCallback, inputProcRefCon: UnsafeMutableRawPointer(context))
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let ok = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, size) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, size) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                    &maxFrames, UInt32(MemoryLayout<UInt32>.size)) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                    &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
            && AudioUnitInitialize(unit) == noErr
        guard ok else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
        if let number = effect.presetNumber,
           var preset = AppleEffectLibrary.factoryPresets(unit).first(where: { Int($0.presetNumber) == number }) {
            AudioUnitSetProperty(unit, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0,
                                 &preset, UInt32(MemoryLayout<AUPreset>.size))
        }
        for (id, value) in effect.parameters {
            AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, value, 0)
        }
        return unit
    }

    /// Applies parameter and bypass changes to the running units. Apple's units
    /// accept parameter changes from any thread while rendering.
    func update(_ effects: [RackEffect]) {
        for effect in effects {
            guard let index = unitIndex[effect.id], let unit = units[index] else { continue }
            bypassed[index] = effect.isBypassed ? 1 : 0
            for (id, value) in effect.parameters {
                AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, value, 0)
            }
        }
    }

    /// Runs the units in order over a non-interleaved stereo block, in place.
    @inline(__always)
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0, frames <= Self.maxFrames else { return }
        let bytes = frames * MemoryLayout<Float>.size
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid
        for index in 0..<count {
            guard let unit = units[index], bypassed[index] == 0 else { continue }
            context.pointee.left = left
            context.pointee.right = right
            bufferList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: UnsafeMutableRawPointer(outLeft))
            bufferList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: UnsafeMutableRawPointer(outRight))
            var flags = AudioUnitRenderActionFlags()
            guard AudioUnitRender(unit, &flags, &timestamp, 0, UInt32(frames), bufferList.unsafeMutablePointer) == noErr else { continue }
            if let l = bufferList[0].mData { memcpy(left, l, bytes) }
            if let r = bufferList[1].mData { memcpy(right, r, bytes) }
        }
        sampleTime += Float64(frames)
    }

    /// Latency the rack adds, in seconds (for diagnostics).
    public var latency: Double {
        var total = 0.0
        for index in 0..<count {
            guard let unit = units[index] else { continue }
            var seconds: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            if AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &seconds, &size) == noErr {
                total += seconds
            }
        }
        return total
    }
}
