import AppKit
import CoreAudio
import Foundation

/// Reads the input-method's real CoreAudio capture state.
///
/// This is deliberately independent from the remote-button state machine.
/// `kAudioProcessPropertyIsRunningInput` is the source of truth for whether
/// Doubao is currently recording, and `kAudioProcessPropertyDevices` tells us
/// which input device it actually opened.
final class DoubaoAudioStateMonitor {
    enum State: String {
        case unavailable
        case inactive
        case active
    }

    struct Snapshot: Equatable {
        let state: State
        let pid: pid_t?
        let processObjectID: AudioObjectID?
        let inputDeviceIDs: [AudioDeviceID]
        let inputDeviceNames: [String]
        /// False when the system cannot report the input method's capture
        /// state (macOS before 14.2, or the compatibility override). The
        /// state is then `.unavailable` even while the input method runs;
        /// `pid` alone says whether it is running.
        var captureObservable = true

        var isRecording: Bool { state == .active }

        var deviceSummary: String {
            guard captureObservable else {
                return L10n.text("兼容模式", "Compatibility mode")
            }
            return inputDeviceNames.isEmpty
                ? "无"
                : inputDeviceNames.joined(separator: "、")
        }
    }

    private static let targetDeviceName = "vRemoteDr 2ch"
    /// `defaults write io.github.ccc333cn.vremoter voiceCompatibilityMode
    /// -bool YES` forces compatibility mode (for testing on new systems);
    /// `NO` forces normal mode; absent means detect.
    static let compatibilityOverrideKey = "voiceCompatibilityMode"

    /// Whether the input method's real capture state can be read.
    let canObserveRecording: Bool

    private var started = false
    private var processObjectID = AudioObjectID(kAudioObjectUnknown)
    private var processPID: pid_t?
    private var boundBundleID: String?
    private var lastSnapshot: Snapshot?
    private var workspaceObservers = [NSObjectProtocol]()

    var onSnapshotChanged: ((Snapshot) -> Void)?

    init() {
        let supported = Self.systemReportsProcessInput()
        let override = UserDefaults.standard.object(
            forKey: Self.compatibilityOverrideKey
        ) as? Bool
        canObserveRecording = override.map { !$0 } ?? supported
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        if canObserveRecording {
            print("[DOUBAO-STATE] capture state supported (\(os))")
        } else {
            print(
                "[DOUBAO-STATE] compatibility mode: " +
                (override == true
                    ? "forced by \(Self.compatibilityOverrideKey)"
                    : "system cannot report input-method recording") +
                " (\(os))"
            )
        }
    }

    /// Probes the HAL instead of trusting the OS version: the process object
    /// list must exist and a process object must expose IsRunningInput
    /// (added in macOS 14.2).
    private static func systemReportsProcessInput() -> Bool {
        var listAddress = processListAddress
        guard AudioObjectHasProperty(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress
        ) else { return false }
        let processes = objectListProperty(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        )
        guard let first = processes.first else {
            return ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(
                    majorVersion: 14,
                    minorVersion: 2,
                    patchVersion: 0
                )
            )
        }
        var runningAddress = runningInputAddress
        return AudioObjectHasProperty(first, &runningAddress)
    }

    private lazy var processListListener: AudioObjectPropertyListenerBlock = {
        [weak self] _, _ in
        DispatchQueue.main.async {
            self?.refreshBindingAndPublish(force: false)
        }
    }

    private lazy var inputStateListener: AudioObjectPropertyListenerBlock = {
        [weak self] _, _ in
        DispatchQueue.main.async {
            self?.publishCurrentSnapshot(force: false)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        guard canObserveRecording else {
            // No HAL process list here; follow the input method's launch
            // and quit through NSWorkspace instead.
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers = [
                NSWorkspace.didLaunchApplicationNotification,
                NSWorkspace.didTerminateApplicationNotification,
            ].map { name in
                center.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.refreshBindingAndPublish(force: false)
                }
            }
            refreshBindingAndPublish(force: true)
            return
        }

        var address = Self.processListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            processListListener
        )
        if status != noErr {
            print("[DOUBAO-STATE] 无法监听音频进程列表: \(Self.describe(status))")
        }
        refreshBindingAndPublish(force: true)
    }

    /// Rebinds to the newly selected input method's process.
    func targetDidChange() {
        unbindProcessObject()
        boundBundleID = nil
        refreshBindingAndPublish(force: true)
    }

    func stop() {
        guard started else { return }
        started = false
        unbindProcessObject()
        lastSnapshot = nil
        guard canObserveRecording else {
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers.forEach(center.removeObserver)
            workspaceObservers.removeAll()
            return
        }

        var address = Self.processListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            processListListener
        )
    }

    /// Synchronous pre-event snapshot. The Option event tap calls this before
    /// the key event reaches Doubao, so the returned value is the old state
    /// that the Option press is about to toggle.
    func snapshotNow() -> Snapshot {
        refreshBindingIfNeeded()
        return readCurrentSnapshot()
    }

    private func refreshBindingAndPublish(force: Bool) {
        refreshBindingIfNeeded()
        publishCurrentSnapshot(force: force)
    }

    private func refreshBindingIfNeeded() {
        let targetBundleID = VoiceInputMethod.current.bundleIdentifier
        if boundBundleID != targetBundleID {
            unbindProcessObject()
            boundBundleID = targetBundleID
        }
        let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: targetBundleID
        ).first { !$0.isTerminated }

        guard let app else {
            if processObjectID != kAudioObjectUnknown {
                unbindProcessObject()
            }
            processPID = nil
            return
        }

        let pid = app.processIdentifier
        guard canObserveRecording else {
            processPID = pid
            return
        }
        let translated = Self.processObject(for: pid)
        guard translated != kAudioObjectUnknown else {
            if processObjectID != kAudioObjectUnknown {
                unbindProcessObject()
            }
            processPID = pid
            return
        }

        guard translated != processObjectID else {
            processPID = pid
            return
        }

        unbindProcessObject()
        processObjectID = translated
        processPID = pid

        var runningAddress = Self.runningInputAddress
        let runningStatus = AudioObjectAddPropertyListenerBlock(
            translated,
            &runningAddress,
            .main,
            inputStateListener
        )

        var devicesAddress = Self.inputDevicesAddress
        let devicesStatus = AudioObjectAddPropertyListenerBlock(
            translated,
            &devicesAddress,
            .main,
            inputStateListener
        )

        print(
            "[DOUBAO-STATE] 已绑定 pid=\(pid) audioProcess=\(translated) " +
            "listeners=\(Self.describe(runningStatus))/\(Self.describe(devicesStatus))"
        )
    }

    private func unbindProcessObject() {
        guard processObjectID != kAudioObjectUnknown else { return }
        var runningAddress = Self.runningInputAddress
        AudioObjectRemovePropertyListenerBlock(
            processObjectID,
            &runningAddress,
            .main,
            inputStateListener
        )
        var devicesAddress = Self.inputDevicesAddress
        AudioObjectRemovePropertyListenerBlock(
            processObjectID,
            &devicesAddress,
            .main,
            inputStateListener
        )
        processObjectID = AudioObjectID(kAudioObjectUnknown)
        processPID = nil
    }

    private func publishCurrentSnapshot(force: Bool) {
        guard started else { return }
        let snapshot = readCurrentSnapshot()
        guard force || snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        print(
            "[DOUBAO-STATE] state=\(snapshot.state.rawValue) " +
            "pid=\(snapshot.pid.map(String.init) ?? "-") " +
            "devices=\(snapshot.deviceSummary)"
        )
        if snapshot.isRecording,
           !snapshot.inputDeviceNames.contains(Self.targetDeviceName)
        {
            print(
                "[DOUBAO-STATE] ⚠️ \(VoiceInputMethod.current.shortName)" +
                "正在录音，但实际输入不是 " +
                Self.targetDeviceName
            )
        }
        onSnapshotChanged?(snapshot)
    }

    private func readCurrentSnapshot() -> Snapshot {
        guard canObserveRecording else {
            return Snapshot(
                state: .unavailable,
                pid: processPID,
                processObjectID: nil,
                inputDeviceIDs: [],
                inputDeviceNames: [],
                captureObservable: false
            )
        }
        guard processObjectID != kAudioObjectUnknown else {
            return Snapshot(
                state: .unavailable,
                pid: processPID,
                processObjectID: nil,
                inputDeviceIDs: [],
                inputDeviceNames: []
            )
        }

        guard let running = Self.uint32Property(
            object: processObjectID,
            selector: kAudioProcessPropertyIsRunningInput,
            scope: kAudioObjectPropertyScopeGlobal
        ) else {
            return Snapshot(
                state: .unavailable,
                pid: processPID,
                processObjectID: processObjectID,
                inputDeviceIDs: [],
                inputDeviceNames: []
            )
        }

        let deviceIDs = Self.objectListProperty(
            object: processObjectID,
            selector: kAudioProcessPropertyDevices,
            scope: kAudioObjectPropertyScopeInput
        )
        let names = deviceIDs.map(Self.deviceName)
        return Snapshot(
            state: running == 0 ? .inactive : .active,
            pid: processPID,
            processObjectID: processObjectID,
            inputDeviceIDs: deviceIDs,
            inputDeviceNames: names
        )
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifierPointer,
                &size,
                &result
            )
        }
        return status == noErr ? result : AudioObjectID(kAudioObjectUnknown)
    }

    private static func uint32Property(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : nil
    }

    private static func objectListProperty(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            object,
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else { return [] }

        var values = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &values
        ) == noErr else { return [] }
        return values
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "未知设备" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        return status == noErr ? value as String : "设备 \(deviceID)"
    }

    private static func describe(_ status: OSStatus) -> String {
        status == noErr ? "OK" : String(status)
    }

    private static var processListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var runningInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var inputDevicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
