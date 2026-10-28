import Foundation
import IOKit.ps

/// Reports plug / unplug and low-battery events.
final class PowerMonitor {
    struct State: Equatable { var percent: Int; var plugged: Bool; var charging: Bool }

    var onEvent: ((HUDKind) -> Void)?
    private var last: State?
    private var source: CFRunLoopSource?
    private var warned: Set<Int> = []

    func start() {
        last = read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue().changed()
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    private func changed() {
        guard let new = read() else { return }
        defer { last = new }
        guard let old = last else { return }
        if new.plugged != old.plugged {
            warned.removeAll()
            onEvent?(.power(percent: new.percent, charging: new.charging, plugged: new.plugged))
        } else if !new.plugged {
            for threshold in [20, 10, 5] where new.percent <= threshold && old.percent > threshold && !warned.contains(threshold) {
                warned.insert(threshold)
                onEvent?(.power(percent: new.percent, charging: false, plugged: false))
            }
        }
    }

    private func read() -> State? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let info = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let plugged = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = (info[kIOPSIsChargingKey] as? Bool) ?? false
            return State(percent: Int((Double(current) / Double(max) * 100).rounded()), plugged: plugged, charging: charging)
        }
        return nil
    }
}
