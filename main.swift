// appvol – Lautstärke einzelner Apps auf macOS regeln (Core Audio Process Taps, macOS 14.4+).
//
//   appvol list                 Audio-Prozesse anzeigen (▶ = spielt gerade Ton ab)
//   appvol <name|pid> <0-100>   Ton der App auf X % setzen; Zahl eintippen + Enter ändert live, Ctrl+C beendet
//
// Funktionsweise: Ein Process Tap greift den Ton der App ab und stummt das Original.
// Ein privates Aggregate-Device spielt ihn mit neuer Lautstärke auf dem Standard-Ausgang ab.

import AudioToolbox
import CoreAudio
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("appvol: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) fehlgeschlagen (OSStatus \(status))") }
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
    getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID(0)).map { id in
        let pid = getValue(id, kAudioProcessPropertyPID, pid_t(-1)) ?? -1
        let bundle = getString(id, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
            ?? (pid > 0 ? (ProcessInfo.processInfo.processIdentifier == pid ? "appvol" : processName(pid)) : "?")
        let playing = (getValue(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0
        return AudioProcess(id: id, pid: pid, bundle: bundle, playing: playing)
    }
}

func processName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 1024)
    return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
}

/// Name-Treffer: Teilstring der Bundle-ID (ohne Groß/Klein). Zahl = PID.
func matches(_ query: String, in procs: [AudioProcess]) -> [AudioProcess] {
    if let pid = pid_t(query) { return procs.filter { $0.pid == pid } }
    return procs.filter { $0.bundle.lowercased().contains(query.lowercased()) && $0.pid != ProcessInfo.processInfo.processIdentifier }
}

func parseVolume(_ s: String) -> Float? {
    guard let v = Float(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")), (0...100).contains(v) else { return nil }
    return v / 100
}

// ---------- Selbsttest (reine Logik, ohne Audio) ----------
if CommandLine.arguments.dropFirst().first == "selftest" {
    let ps = [AudioProcess(id: 1, pid: 10, bundle: "us.zoom.xos", playing: true),
              AudioProcess(id: 2, pid: 11, bundle: "com.apple.WebKit.GPU", playing: false)]
    precondition(matches("Zoom", in: ps).map(\.id) == [1])
    precondition(matches("11", in: ps).map(\.id) == [2])
    precondition(matches("teams", in: ps).isEmpty)
    precondition(parseVolume("40") == 0.4 && parseVolume(" 100% ") == 1 && parseVolume("101") == nil && parseVolume("x") == nil)
    print("selftest ok")
    exit(0)
}

// ---------- CLI ----------
let args = Array(CommandLine.arguments.dropFirst())

if args.first == "list" || args.isEmpty {
    let procs = audioProcesses().sorted { ($0.playing ? 0 : 1, $0.bundle) < ($1.playing ? 0 : 1, $1.bundle) }
    for p in procs { print("\(p.playing ? "▶" : " ") \(String(p.pid).padding(toLength: 7, withPad: " ", startingAt: 0)) \(p.bundle)") }
    if args.isEmpty { print("\nNutzung: appvol <name|pid> <0-100>   (z.B. appvol zoom 40)") }
    exit(0)
}

guard args.count == 2, let startVolume = parseVolume(args[1]) else { fail("Nutzung: appvol <name|pid> <0-100>") }
let targets = matches(args[0], in: audioProcesses())
if targets.isEmpty { fail("kein Audio-Prozess passt zu '\(args[0])' – 'appvol list' zeigt alle") }
print("Regle: " + targets.map { "\($0.bundle) (\($0.pid))" }.joined(separator: ", "))

// Lautstärke wird vom Audio-Thread gelesen; ein Float-Schreibzugriff ist auf arm64 atomar genug für diesen Zweck.
nonisolated(unsafe) var volume: Float = startVolume

// 1. Tap auf die Ziel-Prozesse, Original wird stumm geschaltet
let tapDesc = CATapDescription(stereoMixdownOfProcesses: targets.map(\.id))
tapDesc.uuid = UUID()
tapDesc.muteBehavior = .mutedWhenTapped
tapDesc.isPrivate = true
tapDesc.name = "appvol"
var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(tapDesc, &tapID), "Process Tap anlegen (Audioaufnahme-Freigabe erteilt?)")

// 2. Aggregate-Device: Standard-Ausgang + Tap
guard let outDev = getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)),
      let outUID = getString(outDev, kAudioDevicePropertyDeviceUID) else { fail("kein Standard-Ausgabegerät") }
// Hat der Ausgang selbst Eingänge (Headset-Mikro), kommen die zuerst – die überspringen wir, sonst hört man sich selbst.
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
var aggID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID), "Aggregate-Device anlegen")

func cleanup() {
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
}

// 3. Ton durchreichen: Tap-Eingang × Lautstärke → Ausgang
// shortcut: nimmt Float32 an (Core-Audio-Standard) und folgt keinem Wechsel des Ausgabegeräts – dann appvol neu starten.
var procID: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    let outs = UnsafeMutableAudioBufferListPointer(outData)
    let tapBufs = Array(ins.dropFirst(skipInputs))
    let g = volume
    for (i, out) in outs.enumerated() {
        guard let o = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let n = Int(out.mDataByteSize) / MemoryLayout<Float>.size
        guard !tapBufs.isEmpty, let src = tapBufs[min(i, tapBufs.count - 1)].mData?.assumingMemoryBound(to: Float.self) else {
            memset(o, 0, Int(out.mDataByteSize)); continue
        }
        let m = min(n, Int(tapBufs[min(i, tapBufs.count - 1)].mDataByteSize) / MemoryLayout<Float>.size)
        for k in 0..<m { o[k] = src[k] * g }
        if m < n { for k in m..<n { o[k] = 0 } }
    }
}, "Audio-Verarbeitung anlegen")

check(AudioDeviceStart(aggID, procID), "Audio starten")
print("Läuft mit \(Int(volume * 100)) %. Neue Zahl + Enter ändert, Ctrl+C beendet.")

// Sauber aufräumen, sonst bleibt die App bis zum Prozessende stumm
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        AudioDeviceStop(aggID, procID)
        if let p = procID { AudioDeviceDestroyIOProcID(aggID, p) }
        cleanup()
        print("\nBeendet, Originalton wieder normal.")
        exit(0)
    }
    src.resume()
    _ = Unmanaged.passRetained(src as AnyObject)  // Quelle am Leben halten
}

DispatchQueue.global().async {
    while let line = readLine() {
        if let v = parseVolume(line) { volume = v; print("→ \(Int(v * 100)) %") }
        else if !line.isEmpty { print("Zahl 0-100 eingeben") }
    }
}

dispatchMain()
