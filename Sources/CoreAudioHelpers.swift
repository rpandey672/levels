import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String
    var description: String { "\(operation) failed (\(status.fourCharCode))" }
}

extension OSStatus {
    var fourCharCode: String {
        let n = UInt32(bitPattern: self)
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: n >> UInt32($0)) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let s = String(bytes: bytes, encoding: .ascii) {
            return "'\(s)'"
        }
        return String(self)
    }
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
        guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ object: AudioObjectID,
                       _ selector: AudioObjectPropertySelector,
                       _ initial: T,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "Read property")
        return value
    }

    static func getString(_ object: AudioObjectID,
                          _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "Read string property")
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    static func getObjectIDs(_ object: AudioObjectID,
                             _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "Read property size")
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: unknown, count: count)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids), "Read object list")
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }
}
