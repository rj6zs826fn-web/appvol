// Gemeinsamer Audio-Kern für CLI (main.swift) und Notch-App (App/).
// Ein Process Tap greift den Ton der App ab und stummt das Original;
// ein privates Aggregate-Device spielt ihn mit neuer Lautstärke auf dem Standard-Ausgang ab.

import AudioToolbox
import CoreAudio
import Foundation

struct AudioError: Error, CustomStringConvertible { let description: String }

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw AudioError(description: "\(what) fehlgeschlagen (OSStatus \(status))") }
}

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getValue<T: BitwiseCopyable>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T? {
    var a = addr(sel)
    var v = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
}

func getArray<T: BitwiseCopyable>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, zero: T) -> [T] {
    var a = addr(sel, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var arr = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &arr) == noErr else { return [] }
    return arr
}

func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel)
    var s: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr, let v = s else { return nil }
    return v.takeRetainedValue() as String
}

struct AudioProcess { let id: AudioObjectID; let pid: pid_t; let bundle: String; let playing: Bool }

func audioProcesses() -> [AudioProcess] {
    let me = ProcessInfo.processInfo.processIdentifier
    return getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID(0)).compactMap { id in
        let pid = getValue(id, kAudioProcessPropertyPID, pid_t(-1)) ?? -1
        if pid == me { return nil }
        let bundle = getString(id, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 } ?? processName(pid)
        let playing = (getValue(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0
        return AudioProcess(id: id, pid: pid, bundle: bundle, playing: playing)
    }
}

func processName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 1024)
    return pid > 0 && proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
}

/// Name-Treffer: Teilstring der Bundle-ID (ohne Groß/Klein). Zahl = PID.
func matches(_ query: String, in procs: [AudioProcess]) -> [AudioProcess] {
    if let pid = pid_t(query) { return procs.filter { $0.pid == pid } }
    return procs.filter { $0.bundle.lowercased().contains(query.lowercased()) }
}

/// Höchste Lautstärke pro App: 3 = 300 % (lauter machen, der Limiter verhindert Übersteuern).
let maxBoost: Float = 3

func parseVolume(_ s: String) -> Float? {
    guard let v = Float(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")), (0...maxBoost * 100).contains(v) else { return nil }
    return v / 100
}

// ---------- Gesamtlautstärke (Standard-Ausgabegerät) ----------

func defaultOutputDevice() -> AudioObjectID? {
    getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
}

private var mainVolumeAddr = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)

/// nil, wenn das Gerät keine Lautstärke hat (z.B. manche HDMI-Ausgänge).
func systemVolume() -> Float? {
    guard let dev = defaultOutputDevice() else { return nil }
    var v: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(dev, &mainVolumeAddr, 0, nil, &size, &v) == noErr ? v : nil
}

func setSystemVolume(_ value: Float) {
    guard let dev = defaultOutputDevice() else { return }
    var v = Float32(max(0, min(1, value)))
    AudioObjectSetPropertyData(dev, &mainVolumeAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
}

/// Regelt die Lautstärke der gegebenen Audio-Prozesse, solange das Objekt lebt.
final class VolumeTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    // Vom Audio-Thread gelesen; ein Float-Schreibzugriff ist auf arm64 atomar genug für diesen Zweck.
    private let gain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let meter = UnsafeMutablePointer<Float>.allocate(capacity: 3)  // [Spitze Eingang, Spitze Ausgang, Limiter-Hüllkurve]

    /// Spitzenpegel seit dem letzten Aufruf (0…1), z.B. um zu prüfen, ob überhaupt Ton ankommt.
    func peaks() -> (input: Float, output: Float) {
        defer { meter[0] = 0; meter[1] = 0 }
        return (meter[0], meter[1])
    }

    var volume: Float {
        get { gain.pointee }
        set { gain.pointee = max(0, min(maxBoost, newValue)) }
    }

    init(processes: [AudioObjectID], volume: Float) throws {
        gain.pointee = volume
        meter.initialize(repeating: 0, count: 3)
        do { try start(processes) } catch { stop(); throw error }
    }

    private func start(_ processes: [AudioObjectID]) throws {
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: processes)
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .mutedWhenTapped
        tapDesc.isPrivate = true
        tapDesc.name = "appvol"
        try check(AudioHardwareCreateProcessTap(tapDesc, &tapID), "Process Tap anlegen (Audioaufnahme-Freigabe erteilt?)")

        guard let outDev = defaultOutputDevice(),
              let outUID = getString(outDev, kAudioDevicePropertyDeviceUID) else { throw AudioError(description: "kein Standard-Ausgabegerät") }
        // Hat der Ausgang selbst Eingänge (Headset-Mikro), kommen die zuerst – überspringen, sonst hört man sich selbst.
        let skipInputs = getArray(outDev, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, zero: AudioStreamID(0)).count

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "appvol",
            kAudioAggregateDeviceUIDKey: "appvol-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapDesc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID), "Aggregate-Device anlegen")

        // shortcut: nimmt Float32 an (Core-Audio-Standard) und folgt keinem Wechsel des Ausgabegeräts – dann neu starten.
        let gain = self.gain, meter = self.meter
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            let outs = UnsafeMutableAudioBufferListPointer(outData)
            let tapBufs = Array(ins.dropFirst(skipInputs))
            let g = gain.pointee
            for (i, out) in outs.enumerated() {
                guard let o = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(out.mDataByteSize) / MemoryLayout<Float>.size
                guard !tapBufs.isEmpty, let src = tapBufs[min(i, tapBufs.count - 1)].mData?.assumingMemoryBound(to: Float.self) else {
                    memset(o, 0, Int(out.mDataByteSize)); continue
                }
                let m = min(n, Int(tapBufs[min(i, tapBufs.count - 1)].mDataByteSize) / MemoryLayout<Float>.size)
                // Limiter: Spitzen über `ceiling` werden sofort heruntergeregelt und lösen sich langsam wieder (~60 ms).
                // So wird auch voll ausgesteuerter Ton lauter (mehr Lautheit) statt hart abgeschnitten.
                let ceiling: Float = 0.95, release: Float = 0.9997
                for k in 0..<m {
                    let y = src[k] * g
                    meter[2] = max(abs(y), meter[2] * release)
                    o[k] = meter[2] > ceiling ? y * (ceiling / meter[2]) : y
                    meter[0] = max(meter[0], abs(src[k])); meter[1] = max(meter[1], abs(o[k]))
                }
                if m < n { for k in m..<n { o[k] = 0 } }
            }
        }, "Audio-Verarbeitung anlegen")
        try check(AudioDeviceStart(aggID, procID), "Audio starten")
    }

    /// Gibt alles frei; danach ist der Originalton wieder normal.
    func stop() {
        if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p); procID = nil }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    deinit { stop() }  // gain bleibt bewusst allokiert: der Audio-Thread könnte sonst einen freigegebenen Zeiger lesen
}

func coreSelftest() {
    let ps = [AudioProcess(id: 1, pid: 10, bundle: "us.zoom.xos", playing: true),
              AudioProcess(id: 2, pid: 11, bundle: "com.apple.WebKit.GPU", playing: false)]
    precondition(matches("Zoom", in: ps).map(\.id) == [1])
    precondition(matches("11", in: ps).map(\.id) == [2])
    precondition(matches("teams", in: ps).isEmpty)
    precondition(parseVolume("40") == 0.4 && parseVolume(" 100% ") == 1 && parseVolume("150") == 1.5 && parseVolume("301") == nil && parseVolume("x") == nil)
}
