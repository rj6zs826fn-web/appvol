// Ladeleistung: zeigt neben der Notch die Leistung in Watt, die der Mac gerade aus dem Netzteil zieht.
// Quelle: IOKit „AppleSmartBattery“ → PowerTelemetryData.SystemPowerIn (mW). Nichts davon verlässt den Mac.

import Foundation
import IOKit

@MainActor
final class PowerStore: ObservableObject {
    static let shared = PowerStore()
    /// „61 W“, solange geladen wird – sonst nil.
    @Published var label: String?
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in self.refresh() } }
        refresh()
    }

    func refresh() {
        guard Prefs.shared.isOn(.charging) else { if label != nil { label = nil }; return }
        let new = Self.milliwatts().flatMap { $0 >= 1000 ? "\(Int((Double($0) / 1000).rounded())) W" : nil }
        if new != label { label = new }
    }

    // shortcut: Macs ohne PowerTelemetryData (Intel, Desktop ohne Akku) zeigen nichts; bei Bedarf Spannung × Strom nachrüsten
    nonisolated static func milliwatts() -> Int? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        var p: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(s, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = p?.takeRetainedValue() as? [String: Any],
              d["IsCharging"] as? Bool == true,
              let t = d["PowerTelemetryData"] as? [String: Any] else { return nil }
        return t["SystemPowerIn"] as? Int
    }
}
