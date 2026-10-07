import AppKit
import CoreAudio
import Darwin

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isPlaying: Bool
}

// pid/bundle id don't change per object, so only re-read the playing flag
final class ProcessScanner {
    private var identity: [AudioObjectID: (pid: pid_t, bundleID: String)] = [:]

    func scan() -> [AudioProcess] {
        guard let ids = try? CA.getObjectIDs(CA.system, kAudioHardwarePropertyProcessObjectList) else { return [] }
        let live = Set(ids)
        identity = identity.filter { live.contains($0.key) }

        return ids.compactMap { id in
            let info: (pid: pid_t, bundleID: String)
            if let cached = identity[id] {
                info = cached
            } else {
                guard let pid = try? CA.get(id, kAudioProcessPropertyPID, pid_t(-1)), pid > 0 else { return nil }
                info = (pid, (try? CA.getString(id, kAudioProcessPropertyBundleID)) ?? "")
                identity[id] = info
            }
            let running = (try? CA.get(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0
            return AudioProcess(objectID: id, pid: info.pid, bundleID: info.bundleID, isPlaying: running != 0)
        }
    }
}

// private, but it's the only reliable way to map helpers (WebKit GPU etc) to their app
private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t
private let responsiblePIDFunction: ResponsiblePIDFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                             "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
}()

// audio process -> the app it belongs to
@MainActor
final class AppResolver {
    // call audio comes from these daemons, not FaceTime.app
    static let callsKey = "com.apple.FaceTime"
    private static let callBundleIDs: Set<String> = [
        "com.apple.FaceTime",
        "com.apple.avconferenced",
        "com.apple.telephonyutilities.callservicesd",
    ]
    private static let iconSize = NSSize(width: 28, height: 28)

    private var snapshotValid = false
    private var regularApps: [String: NSRunningApplication] = [:]
    private var bundleByPID: [pid_t: String] = [:]
    private var prefixCandidates: [String] = []

    private var keyByObject: [AudioObjectID: String] = [:]
    private var nameCache: [String: String] = [:]
    private var iconCache: [String: NSImage] = [:]
    private var installedCache: [String: Bool] = [:]

    func invalidate() {
        snapshotValid = false
        keyByObject.removeAll()
    }

    func forget(objectsNotIn live: Set<AudioObjectID>) {
        keyByObject = keyByObject.filter { live.contains($0.key) }
    }

    func key(for process: AudioProcess) -> String {
        if let cached = keyByObject[process.objectID] { return cached }
        let key = resolve(process)
        keyByObject[process.objectID] = key
        return key
    }

    private func resolve(_ process: AudioProcess) -> String {
        if Self.callBundleIDs.contains(process.bundleID) { return Self.callsKey }
        refreshSnapshotIfNeeded()
        if let id = bundleByPID[process.pid] { return id }
        if let parent = responsiblePIDFunction?(process.pid), parent > 0, parent != process.pid,
           let id = bundleByPID[parent] {
            return id
        }
        if !process.bundleID.isEmpty {
            // com.google.Chrome.helper -> com.google.Chrome
            if let id = prefixCandidates.first(where: { process.bundleID.hasPrefix($0 + ".") }) { return id }
            return process.bundleID
        }
        let key = "pid.\(process.pid)"
        if nameCache[key] == nil { nameCache[key] = Self.processName(process.pid) }
        return key
    }

    private func refreshSnapshotIfNeeded() {
        guard !snapshotValid else { return }
        snapshotValid = true
        regularApps = [:]
        bundleByPID = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier else { continue }
            regularApps[id] = app
            bundleByPID[app.processIdentifier] = id
        }
        prefixCandidates = regularApps.keys.sorted { $0.count > $1.count }
    }

    func isInstalled(_ key: String) -> Bool {
        if let cached = installedCache[key] { return cached }
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) != nil
        installedCache[key] = installed
        return installed
    }

    func name(for key: String) -> String {
        if key == Self.callsKey { return "FaceTime & Calls" }
        if let cached = nameCache[key] { return cached }
        refreshSnapshotIfNeeded()
        let name: String
        if let app = regularApps[key], let localized = app.localizedName {
            name = localized
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            let display = FileManager.default.displayName(atPath: url.path)
            name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        } else {
            name = key.split(separator: ".").last.map(String.init) ?? key
        }
        nameCache[key] = name
        return name
    }

    // full app icons are huge, keep a 28pt thumbnail
    func icon(for key: String) -> NSImage {
        if let cached = iconCache[key] { return cached }
        refreshSnapshotIfNeeded()
        let source: NSImage?
        if let app = regularApps[key], let appIcon = app.icon {
            source = appIcon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            source = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            source = nil
        }
        let icon = source.map(Self.thumbnail)
            ?? NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: nil)
            ?? NSImage()
        iconCache[key] = icon
        return icon
    }

    private static func thumbnail(_ image: NSImage) -> NSImage {
        let size = iconSize
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let thumbnail = NSImage(size: size)
        thumbnail.addRepresentation(rep)
        return thumbnail
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "Process \(pid)" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
