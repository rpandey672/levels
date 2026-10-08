import Foundation

// no public API for the audio capture permission, so poke TCC directly.
// if the symbols ever go away we just let the first tap trigger the prompt.
enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static func status() -> Status {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(symbol, to: PreflightFunction.self)
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        let request = unsafeBitCast(symbol, to: RequestFunction.self)
        request(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
