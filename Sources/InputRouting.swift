import CoreAudio
import Foundation

// if a bluetooth mic is the default input, anything that records (facetime, discord,
// dictation) flips the headphones into headset mode: mono, call quality audio.
// keeping the input on the mac's own mic leaves them in normal high quality mode.
enum InputRouting {
    static func preferMacMic() {
        let input = (try? CA.get(CA.system, kAudioHardwarePropertyDefaultInputDevice, CA.unknown)) ?? CA.unknown
        guard input != CA.unknown, isBluetooth(input), let mic = builtInMic(), mic != input else { return }
        var addr = CA.address(kAudioHardwarePropertyDefaultInputDevice)
        var id = mic
        AudioObjectSetPropertyData(CA.system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let transport = transportType(device)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        (try? CA.get(device, kAudioDevicePropertyTransportType, UInt32(0))) ?? 0
    }

    private static func builtInMic() -> AudioDeviceID? {
        let devices = (try? CA.getObjectIDs(CA.system, kAudioHardwarePropertyDevices)) ?? []
        return devices.first { device in
            guard transportType(device) == kAudioDeviceTransportTypeBuiltIn else { return false }
            let inputs = (try? CA.getObjectIDs(device, kAudioDevicePropertyStreams,
                                               scope: kAudioObjectPropertyScopeInput))?.count ?? 0
            return inputs > 0
        }
    }
}
