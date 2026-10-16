import AudioToolbox
import CoreAudio
import Foundation
import PyrateCore

/// Controls the level and sound of one source by tapping its processes.
///
/// A private process tap with `mutedWhenTapped` silences the app's own output while
/// we read it, a private aggregate device clocked by the destination device carries
/// the tapped audio, and an IOProc writes it back out with our gain applied.
/// If Pyrate Sounds quits or crashes, the tap disappears and the app plays normally.
final class TapEngine {
    let sourceID: SourceID
    let processObjectIDs: [AudioObjectID]
    let destinationUID: String
    let chain: ProcessingChain

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var rateListener: PropertyListener?

    @MainActor
    init(sourceID: SourceID, name: String, processObjectIDs: [AudioObjectID], destinationUID: String,
         gain: Float, eq: SourceEQ) throws {
        self.sourceID = sourceID
        self.processObjectIDs = processObjectIDs
        self.destinationUID = destinationUID
        self.chain = ProcessingChain(gain: gain, sampleRate: 48000)

        do {
            try createTap(name: name)
            try createAggregate(name: name)
            chain.setSampleRate(currentSampleRate())
            chain.setEQ(eq)
            // EQ coefficients depend on the sample rate; follow changes to it.
            rateListener = PropertyListener(object: aggregateID, address: Self.nominalRate) { [weak self] in
                guard let self else { return }
                self.chain.setSampleRate(self.currentSampleRate())
            }
            try startIO()
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    static let nominalRate = CAProperty.address(kAudioDevicePropertyNominalSampleRate)

    private func currentSampleRate() -> Double {
        let rate = (try? CAProperty.get(aggregateID, Self.nominalRate, default: Float64(0))) ?? 0
        return rate > 0 ? rate : 48000
    }

    private func createTap(name: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "Pyrate Sounds: \(name)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the audio tap")
    }

    private func createAggregate(name: String) throws {
        let tapUID = try CAProperty.string(tapID, CAProperty.address(kAudioTapPropertyUID))
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pyrate Sounds \(name)",
            kAudioAggregateDeviceUIDKey: OutputDevice.ownedUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: destinationUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: destinationUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "Creating the playback device")
    }

    private func startIO() throws {
        let tapFormat = try CAProperty.get(tapID, CAProperty.address(kAudioTapPropertyFormat), default: AudioStreamBasicDescription())
        guard Self.isFloat32(tapFormat) else {
            throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, context: "Unsupported tap format")
        }
        let tapChannels = max(1, min(2, Int(tapFormat.mChannelsPerFrame)))

        let destination = DeviceControl.objectID(forUID: destinationUID) ?? aggregateID
        let (left, right) = DeviceControl.preferredStereoChannels(of: destination)
        let chain = self.chain

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            TapRenderer.render(input: input, output: output, tapChannels: tapChannels,
                               leftChannel: left - 1, rightChannel: right - 1, chain: chain)
        }, "Starting audio processing")
        try check(AudioDeviceStart(aggregateID, procID), "Starting audio playback")
    }

    func stop() {
        rateListener = nil
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    static func isFloat32(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }
}

/// The realtime render path. No allocation, no locks, no Objective-C messaging.
enum TapRenderer {
    struct Channel {
        var data: UnsafeMutablePointer<Float>
        var stride: Int
        var frames: Int
    }

    @inline(__always)
    static func channel(at index: Int, in list: UnsafeMutableAudioBufferListPointer) -> Channel? {
        var remaining = index
        for buffer in list {
            let count = Int(buffer.mNumberChannels)
            guard count > 0, let data = buffer.mData else { continue }
            if remaining < count {
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * count)
                return Channel(data: data.assumingMemoryBound(to: Float.self) + remaining, stride: count, frames: frames)
            }
            remaining -= count
        }
        return nil
    }

    @inline(__always)
    static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var total = 0
        for buffer in list { total += Int(buffer.mNumberChannels) }
        return total
    }

    static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        tapChannels: Int,
        leftChannel: Int,
        rightChannel: Int,
        chain: ProcessingChain
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        // The tap's channels come after any input streams of the destination device
        // (a headset's microphone, for example), so read them from the end.
        let inCount = channelCount(inList)
        guard inCount >= tapChannels,
              let inL = channel(at: inCount - tapChannels, in: inList) else { return }
        let inR = tapChannels > 1 ? channel(at: inCount - 1, in: inList) ?? inL : inL

        let outCount = channelCount(outList)
        guard outCount > 0 else { return }
        let useLeft = leftChannel < outCount ? leftChannel : 0
        let useRight = rightChannel < outCount ? rightChannel : min(1, outCount - 1)
        guard let outL = channel(at: useLeft, in: outList),
              let outR = channel(at: useRight, in: outList) else { return }
        let mono = useLeft == useRight

        let frames = min(inL.frames, inR.frames, outL.frames, outR.frames)
        guard frames > 0 else { return }

        chain.process(
            inL: inL.data, inLStride: inL.stride, inR: inR.data, inRStride: inR.stride,
            outL: outL.data, outLStride: outL.stride, outR: outR.data, outRStride: outR.stride,
            mono: mono, frames: frames)
    }
}
