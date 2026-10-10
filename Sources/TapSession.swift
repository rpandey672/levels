import CoreAudio
import Foundation

// raw memory so the audio thread never hits ARC
final class GainControl {
    private let storage = UnsafeMutablePointer<Float>.allocate(capacity: 2)

    init(_ gain: Float = 1) { storage.initialize(repeating: gain, count: 2) }
    deinit { storage.deallocate() }

    var target: Float {
        get { storage[0] }
        set { storage[0] = newValue }
    }

    // last applied value, for ramping
    var current: Float {
        get { storage[1] }
        set { storage[1] = newValue }
    }
}

// app -> process tap (muted at source) -> private aggregate [tap + output] -> ioproc * gain
// taps die with the process so a crash just gives you normal audio back.
final class TapSession {
    private(set) var processes: [AudioObjectID]
    let gain: GainControl

    private var description: CATapDescription
    private var tapID = CA.unknown
    private var aggregateID = CA.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "levels.tap", qos: .userInteractive)

    init(name: String,
         processes: [AudioObjectID],
         outputDevice: AudioDeviceID,
         outputUID: String,
         gain: GainControl) throws {
        self.processes = processes
        self.gain = gain
        self.description = Self.makeDescription(name: name, processes: processes, uuid: UUID())

        do {
            var tap = CA.unknown
            try CA.check(AudioHardwareCreateProcessTap(description, &tap), "Creating the audio tap for \(name)")
            tapID = tap
            try createAggregate(name: name, outputUID: outputUID)
            try startIO(outputDevice: outputDevice)
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    // e.g. chrome spun up a new audio helper
    func update(processes newProcesses: [AudioObjectID]) throws {
        guard newProcesses != processes else { return }
        let updated = Self.makeDescription(name: description.name, processes: newProcesses, uuid: description.uuid)
        var addr = CA.address(kAudioTapPropertyDescription)
        var ref: CATapDescription = updated
        try CA.check(AudioObjectSetPropertyData(tapID, &addr, 0, nil,
                                                UInt32(MemoryLayout<CATapDescription>.stride), &ref),
                     "Updating the audio tap")
        description = updated
        processes = newProcesses
    }

    func invalidate() {
        if aggregateID != CA.unknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = CA.unknown
        if tapID != CA.unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = CA.unknown
        }
    }

    // MARK: - Setup

    private static func makeDescription(name: String, processes: [AudioObjectID], uuid: UUID) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = uuid
        description.name = name
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    private func createAggregate(name: String, outputUID: String) throws {
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Levels – \(name)",
            kAudioAggregateDeviceUIDKey: "levels.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ],
            ],
        ]
        var device = CA.unknown
        try CA.check(AudioHardwareCreateAggregateDevice(settings as CFDictionary, &device),
                     "Creating the output device for \(name)")
        aggregateID = device
    }

    private func startIO(outputDevice: AudioDeviceID) throws {
        let gain = self.gain
        var procID: AudioDeviceIOProcID?
        try CA.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, output, _ in
            Renderer.render(input: input, output: output, gain: gain)
        }, "Creating the audio callback")
        ioProcID = procID
        disableHardwareInputs(of: outputDevice)
        try CA.check(AudioDeviceStart(aggregateID, procID), "Starting audio")
    }

    // otherwise the aggregate opens the airpods mic and they drop to call quality
    private func disableHardwareInputs(of outputDevice: AudioDeviceID) {
        guard let ioProcID else { return }
        let deviceInputStreams = (try? CA.getObjectIDs(outputDevice, kAudioDevicePropertyStreams,
                                                       scope: kAudioObjectPropertyScopeInput))?.count ?? 0
        guard deviceInputStreams > 0 else { return }

        var addr = CA.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &addr, 0, nil, &size) == noErr, size > 0 else { return }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        raw.storeBytes(of: unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self),
                       as: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, raw) == noErr,
              let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams),
              let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)
        else { return }

        let streamCount = Int(raw.load(fromByteOffset: countOffset, as: UInt32.self))
        guard streamCount > 1 else { return }
        // device streams first, tap stream last
        for index in 0..<min(deviceInputStreams, streamCount - 1) {
            raw.storeBytes(of: UInt32(0), toByteOffset: flagsOffset + index * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }
        AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, size, raw)
    }
}

// realtime: no allocs, no locks
enum Renderer {
    private struct Channel {
        let samples: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
    }

    static func render(input: UnsafePointer<AudioBufferList>,
                       output: UnsafeMutablePointer<AudioBufferList>,
                       gain: GainControl) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let target = gain.target
        guard let pair = tapChannels(inputs), let outLeft = channel(outputs, 0) else {
            gain.current = target
            return
        }
        let left = pair.0
        let right = pair.1
        let outRight = channel(outputs, 1)

        var frames = min(left.frames, right.frames, outLeft.frames)
        if let outRight { frames = min(frames, outRight.frames) }
        guard frames > 0 else { return }

        var g = gain.current
        let step = (target - g) / Float(frames)

        if let outRight {
            for f in 0..<frames {
                g += step
                outLeft.samples[f * outLeft.stride] = softClip(left.samples[f * left.stride] * g)
                outRight.samples[f * outRight.stride] = softClip(right.samples[f * right.stride] * g)
            }
        } else {
            for f in 0..<frames {
                g += step
                let mono = (left.samples[f * left.stride] + right.samples[f * right.stride]) * 0.5
                outLeft.samples[f * outLeft.stride] = softClip(mono * g)
            }
        }
        gain.current = target
    }

    private static func tapChannels(_ list: UnsafeMutableAudioBufferListPointer) -> (Channel, Channel)? {
        let count = list.count
        guard count > 0 else { return nil }
        let last = list[count - 1]
        guard let data = last.mData, last.mNumberChannels > 0 else { return nil }
        let channels = Int(last.mNumberChannels)
        let samples = data.assumingMemoryBound(to: Float.self)
        let frames = Int(last.mDataByteSize) / (MemoryLayout<Float>.size * channels)

        if channels >= 2 {
            return (Channel(samples: samples, stride: channels, frames: frames),
                    Channel(samples: samples + 1, stride: channels, frames: frames))
        }
        let right = Channel(samples: samples, stride: 1, frames: frames)
        if count >= 2 {
            let previous = list[count - 2]
            if previous.mNumberChannels == 1, let leftData = previous.mData {
                let left = Channel(samples: leftData.assumingMemoryBound(to: Float.self), stride: 1,
                                   frames: Int(previous.mDataByteSize) / MemoryLayout<Float>.size)
                return (left, right)
            }
        }
        return (right, right)
    }

    private static func channel(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int) -> Channel? {
        var base = 0
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            if channels > 0, index < base + channels {
                guard let data = buffer.mData else { return nil }
                return Channel(samples: data.assumingMemoryBound(to: Float.self) + (index - base),
                               stride: channels,
                               frames: Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            }
            base += channels
        }
        return nil
    }

    // only kicks in above 0.9 so boosting doesn't crackle
    @inline(__always)
    private static func softClip(_ x: Float) -> Float {
        let threshold: Float = 0.9
        let magnitude = abs(x)
        if magnitude <= threshold { return x }
        let shaped = threshold + (1 - threshold) * tanhf((magnitude - threshold) / (1 - threshold))
        return x < 0 ? -shaped : shaped
    }
}
