import AppKit
import AudioToolbox  // VirtualMainVolume lives in AudioServices

/// Replaces the system volume/brightness HUD: swallows the media keys, applies the change itself,
/// and shows the level in the notch. Needs Accessibility permission for the key tap.
///
/// ponytail: no keyboard-backlight HUD — current MacBooks have no backlight keys to intercept.
@MainActor
final class HUD: ObservableObject {
    static let shared = HUD()
    enum Kind { case volume, brightness }

    @Published private(set) var kind = Kind.volume
    @Published private(set) var level: Float = 0  // 0...1
    @Published private(set) var muted = false
    @Published private(set) var visible = false

    private var tap: CFMachPort?
    private var hide: DispatchWorkItem?
    private static let step: Float = 1 / 16  // same step as the system HUD

    private init() {}

    func setEnabled(_ on: Bool) {
        on ? start() : stop()
    }

    private func start() {
        guard tap == nil else { return }
        // Shows the Accessibility prompt the first time; once granted, toggle again (or relaunch) to start.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else { return }

        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << 14),  // NX_SYSDEFINED: media keys
            callback: { _, type, event, _ in
                MainActor.assumeIsolated {
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = HUD.shared.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return Unmanaged.passUnretained(event)
                    }
                    return HUD.shared.handle(event) ? nil : Unmanaged.passUnretained(event)
                }
            }, userInfo: nil)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    /// True = we handled it, so the system HUD never sees the key.
    private func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let key = (ns.data1 & 0xFFFF_0000) >> 16
        let isDown = (ns.data1 & 0xFF00) >> 8 == 0xA
        // NX_KEYTYPE_SOUND_UP 0, SOUND_DOWN 1, BRIGHTNESS_UP 2, BRIGHTNESS_DOWN 3, MUTE 7
        guard [0, 1, 2, 3, 7].contains(key) else { return false }
        guard isDown else { return true }  // swallow key-up too

        switch key {
        case 0, 1:
            Volume.muted = false
            Volume.level = max(0, min(1, Volume.level + (key == 0 ? Self.step : -Self.step)))
            show(.volume, Volume.level, muted: false)
        case 7:
            Volume.muted.toggle()
            show(.volume, Volume.level, muted: Volume.muted)
        default:
            guard let current = Brightness.level else { return false }  // no controllable display: let the system handle it
            Brightness.level = max(0, min(1, current + (key == 2 ? Self.step : -Self.step)))
            show(.brightness, Brightness.level ?? current, muted: false)
        }
        return true
    }

    private func show(_ kind: Kind, _ level: Float, muted: Bool) {
        self.kind = kind
        self.level = level
        self.muted = muted
        visible = true
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.visible = false }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

/// Default output device volume via CoreAudio.
private enum Volume {
    private static var device: AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static var level: Float {
        get {
            var value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
            var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value)
            return value
        }
        set {
            var value = Float32(newValue)
            var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    static var muted: Bool {
        get {
            var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            var a = address(kAudioDevicePropertyMute)
            AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value)
            return value != 0
        }
        set {
            var value: UInt32 = newValue ? 1 : 0
            var a = address(kAudioDevicePropertyMute)
            AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }
}

/// Built-in display brightness via the private DisplayServices framework (what the brightness keys use).
/// ponytail: private API; if it's missing, `level` is nil and the system HUD keeps handling brightness.
private enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let get = dlsym(framework, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
    private static let set = dlsym(framework, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }

    static var level: Float? {
        get {
            var value: Float = 0
            guard let get, get(CGMainDisplayID(), &value) == 0 else { return nil }
            return value
        }
        set {
            if let newValue { _ = set?(CGMainDisplayID(), newValue) }
        }
    }
}
