import Foundation
import IOKit.ps

/// Battery level and charger state, pushed by IOKit whenever the power source changes.
@MainActor
final class Battery: ObservableObject {
    static let shared = Battery()

    @Published private(set) var hasBattery = false
    @Published private(set) var level = 100  // percent
    @Published private(set) var charging = false
    @Published private(set) var pluggedIn = false
    /// True for a few seconds after the charger is connected or removed (drives the notch live activity).
    @Published private(set) var justChanged = false

    private init() {
        read(announce: false)
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { Battery.shared.read(announce: true) }
        }, nil).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func read(announce: Bool) {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        guard let first = sources.first,
              let d = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any]
        else { hasBattery = false; return }

        hasBattery = true
        let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
        level = max > 0 ? current * 100 / max : current
        charging = d[kIOPSIsChargingKey] as? Bool ?? false
        let plugged = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        if announce && plugged != pluggedIn {
            justChanged = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.justChanged = false }
        }
        pluggedIn = plugged
    }
}
