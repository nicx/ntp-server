import AppKit

// Zwei Betriebsarten aus einem Binary:
//  - Headless (NTP_HEADLESS gesetzt): reiner Server ohne GUI, für den
//    LaunchDaemon-Betrieb als root auf Port 123. Keine Menüleiste, kein Dock.
//  - Sonst: Menüleisten-App ohne Dock-Icon (.accessory) mit allen Funktionen.
if ProcessInfo.processInfo.environment["NTP_HEADLESS"] != nil {
    runHeadless()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

func runHeadless() {
    let port = UInt16(ProcessInfo.processInfo.environment["NTP_PORT"] ?? "") ?? Config.defaultPort
    let mail = MailConfig.fromEnvironment()

    reportCrashIfAny(mail: mail, port: port)
    CrashMarker.arm(port: port)
    CrashMarker.handleCleanShutdown()

    let server = NTPServer()
    server.onStateChange = {
        let line: String
        switch server.state {
        case .stopped:        line = "\(Config.appName): gestoppt"
        case .running:        line = "\(Config.appName): läuft auf UDP \(port)"
        case .error(let msg): line = "\(Config.appName): Fehler: \(msg)"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    server.start(port: port)
    dispatchMain()   // hält den Prozess am Leben (Network framework nutzt GCD)
}

// Lag beim Start noch ein Marker, endete der Vorlauf unsauber und launchd hat
// per KeepAlive neu gestartet. Der Versand läuft nebenläufig, damit ein
// langsames oder totes Relay den Serverstart nicht verzögert.
func reportCrashIfAny(mail: MailConfig, port: UInt16) {
    guard let stale = CrashMarker.staleMarker() else { return }
    let note = "\(Config.appName): unerwarteter Neustart erkannt (Vorlauf: \(stale))"
    FileHandle.standardError.write(Data((note + "\n").utf8))
    guard mail.isConfigured else { return }

    let host = Host.current().localizedName ?? "unbekannt"
    let body = """
    Der NTP-Server wurde unerwartet neu gestartet.

    Der vorherige Prozess hat sich nicht sauber beendet – er ist abgestürzt oder
    der Mac wurde hart ausgeschaltet. launchd hat den Dienst per KeepAlive
    automatisch wieder gestartet; er läuft jetzt wieder auf UDP \(port).

    Mac:               \(host)
    Vorheriger Lauf:   \(stale)
    Neustart:          \(ISO8601DateFormatter().string(from: Date()))

    Details im Log: \(Config.logPath)
    """
    DispatchQueue.global(qos: .utility).async {
        if let err = MailNotifier.send(mail, subject: "NTP-Server: unerwarteter Neustart", body: body) {
            FileHandle.standardError.write(Data(("\(Config.appName): Absturz-Mail fehlgeschlagen: \(err)\n").utf8))
        }
    }
}
