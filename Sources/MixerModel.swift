import AppKit
import CoreAudio

// saved per bundle id
struct AppSetting: Codable, Equatable {
    // 0...2
    var level: Double = 1
    var muted = false

    var isDefault: Bool { abs(level - 1) < 0.0001 && !muted }

    // squared so the slider feels linear, 2.0 is about +12dB
    var linearGain: Float { muted ? 0 : Float(level * level) }
}

struct AppRow: Equatable {
    let id: String
    let name: String
    let isPlaying: Bool
    let isRunning: Bool
}

private struct AppGroup {
    var objectIDs: [AudioObjectID] = []
    var isPlaying = false
}

private enum DefaultsKey {
    static let settings = "appSettings"
    static let showAll = "showAllApps"
    static let macMic = "useMacMic"
}

// no polling, everything is driven by core audio / workspace notifications
@MainActor
final class MixerModel {
    var onChange: (() -> Void)?

    private(set) var settings: [String: AppSetting] = [:]
    private(set) var permission: AudioCapturePermission.Status = .unknown
    private(set) var outputName = "No output device"
    private(set) var errorMessage: String?
    var showAllApps = UserDefaults.standard.bool(forKey: DefaultsKey.showAll) {
        didSet {
            UserDefaults.standard.set(showAllApps, forKey: DefaultsKey.showAll)
            onChange?()
        }
    }

    // on by default, see InputRouting
    var useMacMic = UserDefaults.standard.object(forKey: DefaultsKey.macMic) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(useMacMic, forKey: DefaultsKey.macMic)
            if useMacMic { InputRouting.preferMacMic() }
            onChange?()
        }
    }

    var hasAdjustments: Bool { !settings.isEmpty }

    // keep io running through short gaps (between songs etc)
    private static let idleGrace: TimeInterval = 5
    // don't tear down while dragging across 100%
    private static let lingerAtDefault: TimeInterval = 3

    private let scanner = ProcessScanner()
    private let resolver = AppResolver()
    private var groups: [String: AppGroup] = [:]
    private var sessions: [String: TapSession] = [:]
    private var gains: [String: GainControl] = [:]
    private var lastHeard: [String: Date] = [:]
    private var defaultSince: [String: Date] = [:]
    private var failedAt: [String: Date] = [:]
    private var output: (id: AudioDeviceID, uid: String)?
    private var permissionRequestPending = false
    private var refreshPending = false
    private var followUp: DispatchWorkItem?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() {
        settings = Self.loadSettings()
        permission = AudioCapturePermission.status()
        readOutputDevice()
        if useMacMic { InputRouting.preferMacMic() }
        installListeners()
        refresh()
    }

    // MARK: - UI state

    func setting(for key: String) -> AppSetting { settings[key] ?? AppSetting() }
    func icon(for key: String) -> NSImage { resolver.icon(for: key) }

    func rows() -> [AppRow] {
        let now = Date()
        var keys = Set<String>()
        for (key, group) in groups {
            let recentlyHeard = lastHeard[key].map { now.timeIntervalSince($0) < 120 } ?? false
            if showAllApps || group.isPlaying || recentlyHeard { keys.insert(key) }
        }
        // keep adjusted apps visible even when closed
        keys.formUnion(settings.keys)
        if resolver.isInstalled(AppResolver.callsKey) { keys.insert(AppResolver.callsKey) }

        return keys.map { key in
            AppRow(id: key,
                   name: resolver.name(for: key),
                   isPlaying: groups[key]?.isPlaying ?? false,
                   isRunning: groups[key] != nil)
        }
        .sorted { a, b in
            // calls first, then running apps
            let aCalls = a.id == AppResolver.callsKey, bCalls = b.id == AppResolver.callsKey
            if aCalls != bCalls { return aCalls }
            if a.isRunning != b.isRunning { return a.isRunning }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Actions

    func setLevel(_ level: Double, for key: String) {
        var setting = self.setting(for: key)
        // snap to 100%
        setting.level = abs(level - 1) < 0.04 ? 1 : min(max(level, 0), 2)
        store(setting, for: key, notify: false)
    }

    func toggleMute(_ key: String) {
        var setting = self.setting(for: key)
        setting.muted.toggle()
        store(setting, for: key, notify: true)
    }

    func reset(_ key: String) { store(AppSetting(), for: key, notify: true) }

    func resetAll() {
        for key in Array(settings.keys) { store(AppSetting(), for: key, notify: false) }
        onChange?()
    }

    func panelOpened() {
        if permission != .authorized {
            let status = AudioCapturePermission.status()
            if status != .unknown { permission = status }
        }
    }

    private func store(_ setting: AppSetting, for key: String, notify: Bool) {
        let previous = self.setting(for: key)
        guard setting != previous else { return }
        if setting.isDefault {
            settings[key] = nil
            defaultSince[key] = Date()
        } else {
            settings[key] = setting
            defaultSince[key] = nil
        }
        gains[key]?.target = setting.linearGain
        saveSettings()
        reconcile(key)
        scheduleFollowUpIfNeeded()
        if notify { onChange?() }
    }

    // MARK: - Events

    private func installListeners() {
        var listAddr = CA.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(CA.system, &listAddr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }

        var outputAddr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(CA.system, &outputAddr, .main) { [weak self] _, _ in
            // airpods take a sec to settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    guard let self, self.readOutputDevice() else { return }
                    self.teardownAll()
                    self.refresh()
                }
            }
        }

        // macos switches the input to the headphones when they connect
        var inputAddr = CA.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(CA.system, &inputAddr, .main) { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    guard let self, self.useMacMic else { return }
                    InputRouting.preferMacMic()
                }
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resolver.invalidate()
                    self?.scheduleRefresh()
                }
            }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.teardownAll() }
        }
    }

    private func updateProcessListeners(_ live: Set<AudioObjectID>) {
        var addr = CA.address(kAudioProcessPropertyIsRunningOutput)
        for (id, block) in processListeners where !live.contains(id) {
            AudioObjectRemovePropertyListenerBlock(id, &addr, .main, block)
            processListeners[id] = nil
        }
        for id in live where processListeners[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            if AudioObjectAddPropertyListenerBlock(id, &addr, .main, block) == noErr {
                processListeners[id] = block
            }
        }
    }

    // batch bursts of notifications into one scan
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshPending = false
                self?.refresh()
            }
        }
    }

    private func refresh() {
        let processes = scanner.scan().filter { $0.pid != ownPID }
        let live = Set(processes.map(\.objectID))
        updateProcessListeners(live)
        resolver.forget(objectsNotIn: live)

        var newGroups: [String: AppGroup] = [:]
        for process in processes {
            let key = resolver.key(for: process)
            newGroups[key, default: AppGroup()].objectIDs.append(process.objectID)
            if process.isPlaying { newGroups[key, default: AppGroup()].isPlaying = true }
        }
        for key in newGroups.keys { newGroups[key]?.objectIDs.sort() }

        let now = Date()
        for (key, group) in newGroups where group.isPlaying { lastHeard[key] = now }
        groups = newGroups

        for key in Set(groups.keys).union(sessions.keys) { reconcile(key) }
        scheduleFollowUpIfNeeded()
        onChange?()
    }

    // only scheduled while something is winding down
    private func scheduleFollowUpIfNeeded() {
        followUp?.cancel()
        followUp = nil
        let needsCheck = sessions.contains { key, session in
            (session.isRunning && groups[key]?.isPlaying != true) || setting(for: key).isDefault
        }
        guard needsCheck else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for key in Array(self.sessions.keys) { self.reconcile(key) }
                self.scheduleFollowUpIfNeeded()
            }
        }
        followUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Taps

    private func reconcile(_ key: String) {
        let setting = self.setting(for: key)
        let objects = groups[key]?.objectIDs ?? []
        let now = Date()

        let lingering = setting.isDefault && sessions[key] != nil &&
            (defaultSince[key].map { now.timeIntervalSince($0) < Self.lingerAtDefault } ?? false)
        let wanted = (!setting.isDefault || lingering) && !objects.isEmpty && permission != .denied

        guard wanted else {
            if let session = sessions.removeValue(forKey: key) { session.invalidate() }
            return
        }
        if permission == .unknown {
            requestPermission()
            return
        }

        let gain = gainControl(for: key)
        gain.target = setting.linearGain

        let shouldRun = groups[key]?.isPlaying == true ||
            (lastHeard[key].map { now.timeIntervalSince($0) < Self.idleGrace } ?? false)

        if let session = sessions[key] {
            if session.processes != objects {
                do {
                    try session.update(processes: objects)
                } catch {
                    session.invalidate()
                    sessions[key] = nil
                    startSession(key, objects: objects, gain: gain, running: shouldRun)
                    return
                }
            }
            session.setRunning(shouldRun)
        } else {
            startSession(key, objects: objects, gain: gain, running: shouldRun)
        }
    }

    private func startSession(_ key: String, objects: [AudioObjectID], gain: GainControl, running: Bool) {
        guard let output else { return }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < 3 { return }
        do {
            sessions[key] = try TapSession(name: resolver.name(for: key),
                                           processes: objects,
                                           outputDevice: output.id,
                                           outputUID: output.uid,
                                           gain: gain,
                                           running: running)
            failedAt[key] = nil
            errorMessage = nil
        } catch {
            failedAt[key] = Date()
            errorMessage = "Couldn't adjust \(resolver.name(for: key)): \(error)"
            onChange?()
        }
    }

    private func gainControl(for key: String) -> GainControl {
        if let existing = gains[key] { return existing }
        let control = GainControl(1)
        gains[key] = control
        return control
    }

    private func requestPermission() {
        guard !permissionRequestPending else { return }
        permissionRequestPending = true
        AudioCapturePermission.request { [weak self] granted in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.permissionRequestPending = false
                self.permission = granted ? .authorized : .denied
                self.refresh()
            }
        }
    }

    private func teardownAll() {
        for session in sessions.values { session.invalidate() }
        sessions.removeAll()
    }

    // MARK: - Output device

    @discardableResult
    private func readOutputDevice() -> Bool {
        let id = (try? CA.get(CA.system, kAudioHardwarePropertyDefaultOutputDevice, CA.unknown)) ?? CA.unknown
        guard id != CA.unknown, let uid = try? CA.getString(id, kAudioDevicePropertyDeviceUID) else {
            let changed = output != nil
            output = nil
            outputName = "No output device"
            return changed
        }
        outputName = (try? CA.getString(id, kAudioObjectPropertyName)) ?? "Output"
        let changed = output?.uid != uid
        output = (id, uid)
        onChange?()
        return changed
    }

    // MARK: - Persistence

    private static func loadSettings() -> [String: AppSetting] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.settings),
              let decoded = try? JSONDecoder().decode([String: AppSetting].self, from: data)
        else { return [:] }
        return decoded.filter { !$0.value.isDefault }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.settings)
        }
    }
}
