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
