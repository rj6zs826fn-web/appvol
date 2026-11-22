// appvol – Lautstärke einzelner Apps auf macOS regeln (Core Audio Process Taps, macOS 14.4+).
//
//   appvol list                 Audio-Prozesse anzeigen (▶ = spielt gerade Ton ab)
//   appvol <name|pid> <0-100>   Ton der App auf X % setzen; Zahl eintippen + Enter ändert live, Ctrl+C beendet

import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("appvol: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "selftest" { coreSelftest(); print("selftest ok"); exit(0) }

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

let tap: VolumeTap
do { tap = try VolumeTap(processes: targets.map(\.id), volume: startVolume) } catch { fail("\(error)") }
print("Läuft mit \(Int(tap.volume * 100)) %. Neue Zahl + Enter ändert, Ctrl+C beendet.")

// Sauber aufräumen, sonst bleibt die App bis zum Prozessende stumm
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { tap.stop(); print("\nBeendet, Originalton wieder normal."); exit(0) }
    src.resume()
    signalSources.append(src)
}

DispatchQueue.global().async {
    while let line = readLine() {
        if let v = parseVolume(line) { tap.volume = v; print("→ \(Int(v * 100)) %") }
        else if !line.isEmpty { print("Zahl 0-100 eingeben") }
    }
}

dispatchMain()
