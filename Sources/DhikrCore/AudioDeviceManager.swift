import CoreAudio
import Foundation

/// Input device management, distilled from VoiceInk's production architecture
/// (research/VoiceInk/Infrastructure/Audio/Devices/AudioDeviceManager.swift).
///
/// Core principles copied from VoiceInk:
///  - never rely on AVFoundation's ".default" device — resolve through CoreAudio,
///    the honest source of truth for routing
///  - identity by UID with modelUID fallback: Bluetooth earbuds (AirPods, soundcore)
///    can change their UID across reconnects, but the model UID is stable
///  - observe BOTH the device list (connect/disconnect) and the default-input
///    property (user routing) — either one can be the event that matters
///  - user-selectable modes: follow the system, or pin a specific device
///
/// UI-free: consumers subscribe via callbacks.
public final class AudioDeviceManager: @unchecked Sendable {

    public struct InputDevice: Equatable, Sendable {
        public let id: AudioDeviceID
        public let uid: String
        public let modelUID: String?
        public let name: String
    }

    public enum Mode: Sendable, Equatable {
        /// follow macOS routing — whatever System Settings says the input is
        case systemDefault
        /// pinned to a user-picked device; falls back to system default while
        /// the device is disconnected, returns to it when it reconnects
        case custom(uid: String, modelUID: String?)
    }

    private var _devices: [InputDevice] = []
    public var devices: [InputDevice] {
        devicesLock.lock()
        defer { devicesLock.unlock() }
        return _devices
    }
    public private(set) var mode: Mode

    /// fires on any change: device list, routing, or mode. Consumers re-resolve.
    public var onChange: (@Sendable () -> Void)?
    /// log sink for session recording evidence
    public var onLog: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "dhikr.audio.devices")
    /// guards `devices` — listener callbacks fire ON queue, so a queue.sync
    /// here would self-deadlock; a lock is reentrancy-safe by acquisition order
    private let devicesLock = NSLock()
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?

    private static let modeKey = "audioInputMode"
    private static let uidKey = "audioInputDeviceUID"
    private static let modelUIDKey = "audioInputDeviceModelUID"

    public init() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.modeKey) == "custom",
           let uid = defaults.string(forKey: Self.uidKey) {
            self.mode = .custom(uid: uid, modelUID: defaults.string(forKey: Self.modelUIDKey))
        } else {
            self.mode = .systemDefault
        }
        refreshDevices()
        installListeners()
    }

    // MARK: - enumeration (CoreAudio, the honest source)

    /// input-capable devices, refreshed — callable from any thread
    @discardableResult
    public func refreshDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &address, 0, nil, &size) == noErr, size > 0 else {
            return devices
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &address, 0, nil, &size, &ids) == noErr else {
            return devices
        }
        let found: [InputDevice] = ids.compactMap { id in
            guard let uid = cfStringProperty(id, kAudioDevicePropertyDeviceUID) as String?,
                  let name = cfStringProperty(id, kAudioDevicePropertyDeviceNameCFString) as String?,
                  hasInputStreams(id)
            else { return nil }
            let modelUID = cfStringProperty(id, kAudioDevicePropertyModelUID) as String?
            return InputDevice(id: id, uid: uid, modelUID: modelUID, name: name)
        }
        devicesLock.lock()
        _devices = found
        devicesLock.unlock()
        return found
    }

    private func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private func cfStringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> CFString? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString>.size)
        var value = "" as CFString
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    // MARK: - resolution

    /// The CoreAudio id of the system default input right now.
    public func systemDefaultDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    /// Resolve which device capture should bind to, per VoiceInk's policy:
    /// custom mode → the pinned device if connected (uid first, modelUID fallback
    /// for earbuds that mint fresh UIDs), else the system default;
    /// systemDefault mode → the system default.
    /// Returns the device UID for capture binding, or nil when nothing is available.
    public func resolveTargetUID() -> String? {
        let current = refreshDevices()
        func systemDefaultUID() -> String? {
            guard let id = systemDefaultDeviceID() else { return nil }
            return current.first(where: { $0.id == id })?.uid
        }
        switch mode {
        case .systemDefault:
            return systemDefaultUID()
        case .custom(let uid, let modelUID):
            if let exact = current.first(where: { $0.uid == uid }) { return exact.uid }
            if let modelUID, let byModel = current.first(where: { $0.modelUID == modelUID }) {
                return byModel.uid
            }
            return systemDefaultUID()
        }
    }

    /// display name of the resolution target (for UI before capture starts)
    public func resolveTargetName() -> String {
        let current = devices.isEmpty ? refreshDevices() : devices
        guard let uid = resolveTargetUID(),
              let dev = current.first(where: { $0.uid == uid }) else { return "No input" }
        return dev.name
    }

    // MARK: - selection

    public func selectSystemDefault() {
        mode = .systemDefault
        let defaults = UserDefaults.standard
        defaults.set("systemDefault", forKey: Self.modeKey)
        defaults.removeObject(forKey: Self.uidKey)
        defaults.removeObject(forKey: Self.modelUIDKey)
        onLog?("mode -> systemDefault")
        onChange?()
    }

    public func selectDevice(uid: String) {
        guard let dev = devices.first(where: { $0.uid == uid }) ?? refreshDevices().first(where: { $0.uid == uid }) else { return }
        mode = .custom(uid: dev.uid, modelUID: dev.modelUID)
        let defaults = UserDefaults.standard
        defaults.set("custom", forKey: Self.modeKey)
        defaults.set(dev.uid, forKey: Self.uidKey)
        defaults.set(dev.modelUID, forKey: Self.modelUIDKey)
        onLog?("mode -> custom \(dev.name)")
        onChange?()
    }

    // MARK: - observation — BOTH signals, like VoiceInk

    private func installListeners() {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onLog?("event: default-input changed")
            self?.onChange?()
        }
        defaultInputListenerBlock = defaultBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, queue, defaultBlock)

        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevices()
            self?.onLog?("event: device list changed")
            self?.onChange?()
        }
        deviceListListenerBlock = listBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, queue, listBlock)
    }

    deinit {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if let block = defaultInputListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultAddress, queue, block)
        }
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if let block = deviceListListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &listAddress, queue, block)
        }
    }
}
