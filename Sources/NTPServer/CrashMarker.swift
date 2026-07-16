import Foundation

// Absturzerkennung für den Daemon. Ein abgestürzter Prozess kann nicht mehr über
// sich selbst berichten, also läuft es indirekt: beim Start wird ein Marker
// gesetzt, bei sauberem Beenden (SIGTERM von launchctl/Shutdown) wieder entfernt.
// Liegt er beim Start noch da, endete der Vorlauf unsauber – launchd hat ihn per
// KeepAlive neu gestartet. Der Marker liegt bewusst unter /usr/local/var und
// nicht in /var/run: letzteres leert macOS beim Boot, ein Absturz beim
// Herunterfahren bliebe damit unsichtbar.
enum CrashMarker {

    // Inhalt des Markers vom Vorlauf, falls dieser nicht sauber beendet wurde.
    static func staleMarker() -> String? {
        guard FileManager.default.fileExists(atPath: Config.statePath) else { return nil }
        let text = (try? String(contentsOfFile: Config.statePath, encoding: .utf8)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func arm(port: UInt16) {
        let dir = (Config.statePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "pid=\(getpid()) port=\(port) gestartet=\(stamp)\n"
        try? text.write(toFile: Config.statePath, atomically: true, encoding: .utf8)
    }

    static func disarm() {
        try? FileManager.default.removeItem(atPath: Config.statePath)
    }

    // Muss stark referenziert bleiben, sonst räumt ARC die Quellen sofort ab.
    // Static und nicht global in main.swift: dortige Top-Level-Variablen werden
    // in Quelltext-Reihenfolge initialisiert, und runHeadless() läuft davor.
    private static var signalSources: [DispatchSourceSignal] = []

    // SIGTERM (launchctl bootout, Shutdown) und SIGINT sind ein sauberes Ende –
    // Marker weg, damit der nächste Start ihn nicht als Absturz meldet.
    // DispatchSource statt signal(): im echten Handler wären nur
    // async-signal-sichere Aufrufe erlaubt, Dateizugriff gehört nicht dazu.
    static func handleCleanShutdown() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                disarm()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}
